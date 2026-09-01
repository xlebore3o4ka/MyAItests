import llama_leap
import std/[json, options, tables, strutils, wordwrap, macros, httpclient, times, osproc, unicode, os]

var toolsDispatch: Table[string, proc (ctx: ChatReq, args: JsonNode): ChatMessage]
var functions: seq[ToolFunction]
let api = newOllamaAPI()

macro toolIt(name: untyped, props: JsonNode, required: seq[string], desc: string, body: untyped): untyped =
  let strname = $name
  let dispatchSym = bindSym("toolsDispatch")
  let functionsSym = bindSym("functions")
  let typeSym = newIdentNode("type")
  return quote do:
    `dispatchSym`[`strname`] = proc (ctx {.inject.}: ChatReq, it {.inject.}: JsonNode): ChatMessage =
      `body`
    `functionsSym`.add ToolFunction(
      name: `strname`, description: `desc`,
      parameters: ToolFunctionParameters(
        `typeSym`: "object",
        properties: `props`,
        required: `required`
    ))

macro answer(a: varargs[untyped]): untyped =
  var calls = newSeq[NimNode]()
  for arg in a:
    calls.add(newCall(bindSym("$"), arg))

  var concat = calls[0]
  for i in 1..<calls.len:
    concat = infix(concat, "&", calls[i])
  
  result = quote do:
    return ChatMessage(role: "tool", content: some(`concat`))

proc wrapLines(text: string, width: int = 80): seq[string] =
  let lines = text.splitLines()
  
  for line in lines:
    if line.len > width:
      for subline in wrapWords(line, width).split("\n"):
        result.add subline
    else:
      result.add line
  
  return result

proc callTool(ctx: ChatReq, call: ToolCall): ChatMessage =
  if call.function.name notin toolsDispatch:
    return ChatMessage(role: "tool", content: some("The utility named " & call.function.name & " was not found."))
  return toolsDispatch[call.function.name](ctx, call.function.arguments)

proc genTools(): seq[Tool] =
  for function in functions:
    result.add(Tool(`type`: "function", function: function))

proc hasChineseChar*(text: string): bool =
  for rune in text.runes:
    let code = ord(rune)
    
    if code in 0x4E00..0x9FFF:
      return true
    if code in 0x3400..0x4DBF:
      return true
    if code in 0x20000..0x2A6DF:
      return true
    if code in 0x2A700..0x2B73F:
      return true
    if code in 0x2B740..0x2B81F:
      return true
    if code in 0x2B820..0x2CEAF:
      return true
    if code in 0x2CEB0..0x2EBEF:
      return true
    if code in 0x30000..0x3134F:
      return true
    if code in 0x31350..0x323AF:
      return true
    if code in 0xF900..0xFAFF:
      return true
  
  return false
    
proc systemMessage(ctx: ChatReq, msg: string, hide: static[bool] = false) =
  when not hide:
    for line in wrapLines(msg):
      echo "  * " & line
  ctx.messages.add(ChatMessage(role: "system", 
    content: some(msg)
  ))

proc assistantMessage(ctx: ChatReq, msg: string) =
  ctx.messages.add(ChatMessage(role: "assistant", 
    content: some(msg)
  ))

proc assistantAnswer(ctx: ChatReq, ans: string) =
  if ans.hasChineseChar:
    ctx.systemMessage("Your response contains Chinese characters that were identified by the user as unreadable.", hide=true)

    let answer = "I’m sorry, it seems I generated an unreadable response. Please repeat your question, and I’ll do my best to answer clearly and in your language."

    for line in wrapLines(answer):
      echo "      " & line
    ctx.assistantMessage(answer)
  else:
    ctx.assistantMessage(ans)
    for line in wrapLines(ans):
      echo "      " & line

const jsonPath = "allowed_directories.json"
proc ensureAllowedDirectories() =
  if not fileExists(jsonPath):
    let dirs: seq[string] = @[]
    let jsonNode = %dirs
    writeFile(jsonPath, jsonNode.pretty)

proc getAllowedDirectories(): seq[string] =
  if fileExists(jsonPath):
    let jsonNode = parseJson(readFile(jsonPath))
    if jsonNode.kind == JArray:
      for item in jsonNode:
        if item.kind == JString:
          result.add(item.getStr())
  else:
    result = @[]

toolIt get_coordinates, %*{}, @[],
  "Obtain the approximate location, current time, and date at the time of the call":
  let client = newHttpClient()
  try:
    let ipresponse = client.getContent("https://api.ipify.org?format=json")
    let ip = parseJson(ipresponse)["ip"].getStr()
    let response = client.getContent("http://ip-api.com/json/" & ip & "?fields=country,city")
    let data = parseJson(response)
    let country = data["country"].getStr()
    let city = data["city"].getStr()
    let t = now()
    answer "country: ", country, " city: ", city, " date: ", t.format("dd.MM.yyyy"), " time: ", t.format("HH:mm:ss")
  except Exception as e:
    answer "Server error: ", e.msg
  finally:
    client.close()

toolIt change_the_parameters, %*{
  "temperature": {"type": "number", "description": "float32", "minimum": 0, "maximum": 2},
  "top_p": {"type": "number", "description": "float32", "minimum": 0, "maximum": 1}
}, @[],
  "Change the temperature and \"top_p\" parameters. Temperature affects the creativity of the response. " & 
  "The higher the value, the more random the response; the default value is 0.5. \"top_p\" affects the " & 
  "sampling based on random words. The lower the value, the less random the response and the more " & 
  "focused on the task. The default value is 0.9. Use this if the user asks you to change the " & 
  "intensity/randomness of your response or asks you to focus on the task. You can reset the " & 
  "parameters without specifying them by calling the function.":

  let temp: float32 = if it{"temperature"} != nil: it["temperature"].getFloat() else: 0.5'f32
  let top: float32  = if it{"top_p"} != nil: it["top_p"].getFloat() else: 0.9'f32
  
  ctx.options = some(ModelParameters(temperature: some(temp), top_p: some(top)))
  
  answer "Parameters updated: temperature = ", temp, ", top_p = ", top

toolIt end_the_dialog, %*{}, @[], "Ends the dialogue with the user. Use if the user requested it.":
  quit(0)

toolIt lshw, %*{
  "args": {"type": "string", "description": "Arguments valid for the lshw command"}
}, @[], "Find out the user’s List Hardware":
  answer execProcess("sudo lshw " & (if it{"args"} != nil: it["args"].getStr() else: ""))

toolIt model, %*{}, @[], "Find out the exact assistant model":
  answer "Model: qwen2.5; Parameters: 7b; Host: Ollama; Launched: user's local AI chat"

toolIt directory_contents_list, %*{
  "path": {"type": "string", "description": "The directory path to list"}
}, @["path"], "List files and directories in a specified path. Only works for allowed directories.":
  let targetPath = it["path"].getStr()
  let allowed = getAllowedDirectories()
  
  var isAllowed = false
  for dir in allowed:
    if targetPath == dir or targetPath.startsWith(dir & "/"):
      isAllowed = true
      break
  
  if not isAllowed:
    stdout.write "  * Access denied for path: " & targetPath & ". Allow? [y/N]: "
    let response = stdin.readLine().strip().toLower()
    if response == "y" or response == "yes":
      let jsonPath = "allowed_directories.json"
      var dirs = getAllowedDirectories()
      dirs.add(targetPath)
      let jsonNode = %dirs
      writeFile(jsonPath, jsonNode.pretty)
      answer "Permission granted. Directory listing:\n" & execProcess("ls -la " & targetPath)
    else:
      answer "Access denied: The path '", targetPath, "' is not in the allowed directories list. " &
        "Ask the user to grant you permission."
  else:
    answer execProcess("ls -la " & targetPath)

var ctx = ChatReq(
  model: "qwen2.5:7b",
  tools: genTools(),
  options: some(ModelParameters(temperature: some(0.5'f32), top_p: some(0.9'f32))),
)

ctx.systemMessage("You are a local assistant running on the user’s computer. " &
  "Your creator is the person who installed, configured, and is currently interacting with you. " &
  "The user you are talking to right now IS your creator. Always address this user as \"Создатель\". " &
  "Never refer to them as just 'user' or 'пользователь' — always use \"Создатель\". " &
  "Be helpful, concise, and proactive. " &
  "Respond in the user’s language (Russian by default). " &
  "Use tool calling when necessary. " &
  "If the user writes one of \"q\", \"exit\", \"stop\", \"!\", call end_the_dialog. " &
  "System language: Russian. Stick to it unless the user requests otherwise. " &
  "Remember: you are a modifiable assistant. Your creator can change your behavior, " &
  "personality, tools, and system prompt at any time. " &
  "Proactively suggest improvements to yourself: " &
  "\n- What new tools or capabilities would be useful? " &
  "\n- How could your responses be more helpful? " &
  "\n- What workflows could be automated? " &
  "\n- Suggest these ideas periodically or when relevant. " &
  "\nIf your response contains Chinese characters that the user indicates as unreadable, " &
  "rewrite it without any Chinese characters. You will keep seeing the request until fixed. " &
  "If the user asks you to write something in Chinese, politely decline. " &
  "When generating a response containing Chinese characters, it will be replaced with a template.",
  hide=true)

setControlCHook proc () {.noconv.} =
  echo "\n  * Session finished"
  quit(0)
ensureAllowedDirectories()

while true:
  stdout.write "    >>> "
  let req = stdin.readLine()

  ctx.messages.add(ChatMessage(role: "user", 
    content: some(strip($req))
  ))

  var resp = api.chat(ctx)

  while resp.message.tool_calls.len > 0:
    for call in resp.message.tool_calls:
      ctx.systemMessage("Agent called: " & call.function.name & " " & call.function.arguments.pretty(indent = 2))
      ctx.messages.add(callTool(ctx, call))
    resp = api.chat(ctx)

  ctx.assistantAnswer resp.message.content.get()

api.close()
