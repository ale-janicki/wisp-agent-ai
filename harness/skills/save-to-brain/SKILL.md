---
name: save-to-brain
description: Use when {{USER_NAME}} explicitly asks to save a file, photo, document or receipt, with phrases like "salva isso", "salva essa foto", "guarda esse PDF", "arquiva isso", "save this". Files the binary into `{{BRAIN_DIR}}/arquivos/` and writes or updates the brain note that links it. NOT for attachments sent without asking to save them; those are read, answered, and left where they are.
---

# Save to brain

{{USER_NAME}} sends a file and asks to save it. Two things must happen, always together: the **file** goes into `{{BRAIN_DIR}}/arquivos/`, and a **note** in the brain says what it is and links it. A file with no note cannot be found; a note with no file is a dead link.

**Only on an explicit command.** An attachment without "salva / guarda / arquiva" (or the equivalent) is not filed.

## Folders

Inside `{{BRAIN_DIR}}/arquivos/`, one folder per kind. Reuse one that fits; create a new one only when none does, and say so in the reply.

| Folder | What goes there |
|---|---|
| `recibos/` | receipts, paid invoices, statements |
| `contratos/` | contracts and signed proposals |
| `documentos/` | IDs, certificates, official papers |
| `fotos/` | photos worth keeping |
| `diversos/` | tickets, bookings, anything else |

## Steps

1. **Locate the file.** The path is given in the message or the conversation. Create `{{BRAIN_DIR}}/arquivos/` if it does not exist yet.
2. **Read the file** (PDF text, image) to learn what it is: issuer, date, amount, document number. Do not guess a field you could not read: leave it out and say so.
3. **Name it** `YYYY-MM-DD-<short-kebab-description>.<ext>`, the date being the document's date, not today's. Never overwrite: if the name exists and the checksum is identical, it is already saved; if different, add `-2`.
4. **Copy** it into the folder, then verify the size. Leave the original where it was.
5. **The note.** Prefer updating the note that already owns the topic. Otherwise create `{{BRAIN_DIR}}/notas/<same-basename>.md` and add its one-line entry to `{{BRAIN_DIR}}/index.md`.
   Link by file name: `[[2026-08-07-recibo-luz.pdf|PDF]]`, or embed with `![[file.pdf]]` / `![[photo.jpg]]` in a new note. Never a `file://` link.
   The note has a one-line summary: what the document is, its date, the amount or number when it has one, and the embed. Money is integer cents in any calculation; format only when writing.
6. **Reply** in one or two lines: what it was, the path it went to, the note it went into.

## Don'ts

- Never delete or move the original.
- Never invent a field (amount, number, date) that the document does not show.
- Never send the file anywhere outside this computer.
