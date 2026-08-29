import llama_leap
import std/[json, options, tables, strutils, wordwrap, macros, httpclient, times, sequtils, linenoise]

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
  "Change the temperature and “top_p” parameters. Temperature affects the creativity of the response. " & 
  "The higher the value, the more random the response; the default value is 0.5. “top_p” affects the " & 
  "sampling based on random words. The lower the value, the less random the response and the more " & 
  "focused on the task. The default value is 0.9. Use this if the user asks you to change the " & 
  "intensity/randomness of your response or asks you to focus on the task. You can reset the " & 
  "parameters without specifying them by calling the function.":

  let temp: float32 = if it{"temperature"} != nil: it["temperature"].getFloat() else: 0.5'f32
  let top: float32  = if it{"top_p"} != nil: it["top_p"].getFloat() else: 0.9'f32
  
  ctx.options = some(ModelParameters(temperature: some(temp), top_p: some(top)))
  
  answer "Parameters updated: temperature = ", temp, ", top_p = ", top

var ctx = ChatReq(
  model: "qwen2.5:7b",
  tools: genTools(),
  options: some(ModelParameters(temperature: some(0.2'f32), top_p: some(0.9'f32))),
)

ctx.messages.add(ChatMessage(role: "system", 
  content: some("You are an assistant. Be helpful and concise. Respond in the user’s language. Use tool calling if necessary.")
))

while true:
  let req = readLine("    >>> ")

  if req.isNil:
    echo "  * Session finished"
    break

  ctx.messages.add(ChatMessage(role: "user", 
    content: some(strip($req))
  ))

  var resp = api.chat(ctx)

  while resp.message.tool_calls.len > 0:
    for call in resp.message.tool_calls:
      echo "  * Agent called: ", call.function.name, " ", $call.function.arguments
      ctx.messages.add(callTool(ctx, call))
    resp = api.chat(ctx)

  let ans = resp.message.content.get()
  for line in wrapLines(ans):
    echo "      " & line

  ctx.messages.add(ChatMessage(role: "assistant", 
    content: some(ans)
  ))

api.close()