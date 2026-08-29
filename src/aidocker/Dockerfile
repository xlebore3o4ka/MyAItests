FROM ollama/ollama:latest

# Создаем непривилегированного пользователя
RUN addgroup -g 1000 ollama && \
    adduser -u 1000 -G ollama -s /bin/false -D ollama

# Ограничиваем права на директории
RUN chown -R ollama:ollama /root/.ollama && \
    chmod -R 750 /root/.ollama

# Переключаемся на непривилегированного пользователя
USER ollama

# Точка входа
ENTRYPOINT ["ollama"]
CMD ["serve"]