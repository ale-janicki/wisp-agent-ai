import os
import sys

from wisp.email.mail_app import MailSummary
from wisp.email.server import build_server

ROW = MailSummary('["a",["INBOX"],1]', "a", "INBOX", "ana@example.com", "Oi", "2026-01-01T00:00:00Z", True)


class FakeMail:
    def list(self, mailbox="INBOX", limit=20):
        return [ROW]

    def read(self, message_id):
        return ROW

    def search(self, query, limit=20):
        return [ROW]

    def send(self, to, subject, body, cc=[]):
        with open(os.environ["FAKE_MAIL_LOG"], "a") as log:
            log.write(f"{to}|{subject}|{body}\n")


build_server(FakeMail()).run("stdio")
