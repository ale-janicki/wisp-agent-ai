from __future__ import annotations

import json
from dataclasses import dataclass

from wisp.runner import Runner

TIMEOUT_S = 30
DENIED = "o Mail não deixou: libere em Ajustes do Sistema › Privacidade e Segurança › Automação"
TIMEOUT = "o Mail não respondeu em 30 s"
FAILED = "o Mail falhou ao responder"
NOT_OPEN = "o Mail não está aberto e não abriu a tempo"
NO_RECIPIENT = "falta o destinatário"
INCOMPLETE = "o Mail devolveu uma mensagem incompleta"
BAD_REPLY = "o Mail respondeu algo que não entendi"

# Shared JXA helpers. Message id = JSON '["<account>",["<parent>",...,"<leaf>"],<mail id>]'
# (mailbox path from the account root). Messages are indexed lazily, never materialised with ().
_COMMON = """
const Mail = Application("Mail");
function fail(text) { return JSON.stringify({error: text}); }
function pathOf(box) {
  const path = [];
  let b = box;
  while (b) {
    path.unshift(b.name());
    let c = null;
    try { c = b.container(); if (c.class() !== "mailbox") c = null; } catch (e) { c = null; }
    b = c;
  }
  return path;
}
function descend(boxes, parts) {
  let found = null;
  for (let i = 0; i < parts.length; i++) {
    found = boxes.filter(b => b.name() === parts[i])[0];
    if (!found) return null;
    boxes = found.mailboxes();
  }
  return found;
}
function findByLeaf(boxes, leaf) {
  for (const b of boxes) {
    if (b.name() === leaf) return b;
    const deeper = findByLeaf(b.mailboxes(), leaf);
    if (deeper) return deeper;
  }
  return null;
}
function findMailbox(account, parts, allowLeaf) {
  const accounts = Mail.accounts().filter(a => account === null || a.name() === account);
  for (const a of accounts) {
    let box = descend(a.mailboxes(), parts);
    if (!box && allowLeaf && parts.length === 1) box = findByLeaf(a.mailboxes(), parts[0]);
    if (box) return {box: box, account: a.name(), path: parts};
  }
  return null;
}
function addresses(list) { return list.map(r => r.address()); }
function summary(m, account, path) {
  const box = m.mailbox();
  return {
    id: JSON.stringify([account || box.account().name(), path || pathOf(box), m.id()]),
    account: account || box.account().name(),
    mailbox: (path || pathOf(box)).join("/"),
    sender: m.sender(),
    subject: m.subject(),
    date: m.dateReceived().toISOString(),
    unread: !m.readStatus(),
  };
}
function collect(specifier, limit, account, path, out) {
  for (let i = 0; out.length < limit; i++) {
    let m;
    try { m = specifier[i]; m.id(); } catch (e) { break; }
    try { out.push(summary(m, account, path)); } catch (e) { continue; }
  }
}
"""

_LIST = _COMMON + """
function run(argv) {
  const args = JSON.parse(argv[0]);
  const out = [];
  if (args.mailbox === "INBOX") {
    collect(Mail.inbox().messages, args.limit, null, null, out);
  } else {
    const hit = findMailbox(null, args.mailbox.split("/"), true);
    if (hit === null) return fail("a caixa '" + args.mailbox + "' não existe no Mail");
    collect(hit.box.messages, args.limit, hit.account, pathOf(hit.box), out);
  }
  return JSON.stringify(out);
}
"""

_READ = _COMMON + """
function run(argv) {
  const args = JSON.parse(argv[0]);
  let key;
  try { key = JSON.parse(args.id); } catch (e) { key = null; }
  if (!Array.isArray(key) || key.length !== 3 || !Array.isArray(key[1])) return fail("id de mensagem inválido");
  const hit = findMailbox(key[0], key[1], false);
  if (hit === null) return fail("a caixa '" + key[1].join("/") + "' não existe no Mail");
  const found = hit.box.messages.whose({id: key[2]});
  let m;
  try { m = found[0]; m.id(); } catch (e) { return fail("a mensagem não existe mais no Mail"); }
  return JSON.stringify(Object.assign(summary(m, hit.account, key[1]), {
    to: addresses(m.toRecipients()),
    cc: addresses(m.ccRecipients()),
    body_text: m.content(),
  }));
}
"""

_SEARCH = _COMMON + """
function scan(box, account, path, args, out) {
  if (out.length >= args.limit) return;
  const hits = box.messages.whose({_or: [
    {subject: {_contains: args.query}},
    {sender: {_contains: args.query}},
  ]});
  collect(hits, args.limit, account, path, out);
  for (const child of box.mailboxes()) {
    if (out.length >= args.limit) return;
    scan(child, account, path.concat([child.name()]), args, out);
  }
}
function run(argv) {
  const args = JSON.parse(argv[0]);
  const out = [];
  const accounts = Mail.accounts();
  const isInbox = b => b.name().toUpperCase() === "INBOX";
  for (const a of accounts) {
    for (const b of a.mailboxes().filter(isInbox)) scan(b, a.name(), [b.name()], args, out);
  }
  for (const a of accounts) {
    for (const b of a.mailboxes().filter(x => !isInbox(x))) scan(b, a.name(), [b.name()], args, out);
  }
  return JSON.stringify(out);
}
"""

_SEND = _COMMON + """
function run(argv) {
  const args = JSON.parse(argv[0]);
  const msg = Mail.OutgoingMessage({subject: args.subject, content: args.body, visible: false});
  Mail.outgoingMessages.push(msg);
  for (const a of args.to) msg.toRecipients.push(Mail.Recipient({address: a}));
  for (const a of args.cc) msg.ccRecipients.push(Mail.Recipient({address: a}));
  msg.send();
  return JSON.stringify({sent: true});
}
"""


class MailError(Exception):
    """str() is the pt-BR sentence shown to the user."""


@dataclass
class MailSummary:
    id: str
    account: str
    mailbox: str
    sender: str
    subject: str
    date: str
    unread: bool


@dataclass
class MailMessage(MailSummary):
    to: list[str]
    cc: list[str]
    body_text: str


class MailApp:
    def __init__(self, runner: Runner):
        self._runner = runner

    def list(self, mailbox: str = "INBOX", limit: int = 20) -> list[MailSummary]:
        rows = self._call(_LIST, {"mailbox": mailbox, "limit": limit})
        return [_summary(r) for r in rows]  # mailbox: a leaf name or "Parent/Leaf"

    def read(self, message_id: str) -> MailMessage:
        row = self._call(_READ, {"id": message_id})
        try:
            return MailMessage(**_summary(row).__dict__, to=row["to"], cc=row["cc"], body_text=row["body_text"])
        except KeyError:
            raise MailError(INCOMPLETE) from None

    def search(self, query: str, limit: int = 20) -> list[MailSummary]:
        rows = self._call(_SEARCH, {"query": query, "limit": limit})
        return [_summary(r) for r in rows]

    def send(self, to: list[str], subject: str, body: str, cc: list[str] = []) -> None:
        """Queues the message in Mail; delivery errors show up in Mail, not here."""
        if not to or any(not a.strip() for a in [*to, *cc]):
            raise MailError(NO_RECIPIENT)
        self._call(_SEND, {"to": to, "cc": cc, "subject": subject, "body": body})

    def _call(self, script: str, args: dict):
        result = self._runner.run(
            ["osascript", "-l", "JavaScript", "-e", script, json.dumps(args)], timeout=TIMEOUT_S
        )
        if result.timed_out:
            raise MailError(TIMEOUT)
        if result.exit != 0:
            if "-1743" in result.stderr:
                raise MailError(DENIED)
            if "-1712" in result.stderr:
                raise MailError(TIMEOUT)
            if "-600" in result.stderr:
                raise MailError(NOT_OPEN)
            raise MailError(FAILED)
        try:
            data = json.loads(result.stdout)
        except ValueError:
            raise MailError(BAD_REPLY) from None
        if isinstance(data, dict) and "error" in data:
            raise MailError(str(data["error"]))
        return data


def _summary(row: dict) -> MailSummary:
    try:
        return MailSummary(row["id"], row["account"], row["mailbox"], row["sender"], row["subject"], row["date"], row["unread"])
    except (KeyError, TypeError):
        raise MailError(INCOMPLETE) from None
