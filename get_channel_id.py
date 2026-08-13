import os

from telethon import TelegramClient
from telethon.sessions import StringSession


API_ID = int(os.environ["TELEGRAM_API_ID"])
API_HASH = os.environ["TELEGRAM_API_HASH"]
SESSION = os.environ["TELEGRAM_SESSION"]


client = TelegramClient(
    StringSession(SESSION),
    API_ID,
    API_HASH
)


async def main():
    print("\nCanais encontrados:\n")

    async for dialog in client.iter_dialogs():
        if dialog.is_channel:
            print(f"{dialog.name} -> {dialog.id}")


with client:
    client.loop.run_until_complete(main())
