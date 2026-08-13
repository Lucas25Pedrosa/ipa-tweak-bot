import os
import requests


BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]

url = f"https://api.telegram.org/bot{BOT_TOKEN}/getUpdates"

response = requests.get(
    url,
    timeout=30
)

response.raise_for_status()

data = response.json()

if not data.get("ok"):
    raise RuntimeError(
        f"Erro da API do Telegram: {data}"
    )

updates = data.get("result", [])

if not updates:
    raise RuntimeError(
        "Nenhuma mensagem encontrada. "
        "Envie /start para o bot e rode novamente."
    )

print()
print("Conversas encontradas:")
print()

seen = set()

for update in updates:
    message = (
        update.get("message")
        or update.get("edited_message")
    )

    if not message:
        continue

    chat = message.get("chat", {})

    chat_id = chat.get("id")

    if chat_id is None:
        continue

    if chat_id in seen:
        continue

    seen.add(chat_id)

    first_name = chat.get(
        "first_name",
        ""
    )

    username = chat.get(
        "username",
        ""
    )

    chat_type = chat.get(
        "type",
        ""
    )

    print(
        f"Chat ID: {chat_id}"
    )
    print(
        f"Nome: {first_name}"
    )
    print(
        f"Username: @{username}"
        if username
        else "Username: —"
    )
    print(
        f"Tipo: {chat_type}"
    )
    print()
