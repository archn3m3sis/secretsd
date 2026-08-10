# secretsd

**A terminal credential platform for agentic workflows and note vaults.**
Bridging the secure informational gap between man and machine.

`secretsd` is a full-screen terminal program built on [SOPS](https://github.com/getsops/sops)
and [age](https://github.com/FiloSottile/age). It manages the credentials you already have,
tells you the truth about their security posture, and lets an AI agent work alongside them
**without ever seeing a secret value**.

---

## Why this exists

I have spent years around power users and security professionals, and I have watched all of
this happen. Not once. Repeatedly. By people who know better, including me.

The engineer whose `~/.ssh/id_rsa` has no passphrase, `ForwardAgent yes` set globally because
it "makes jump hosts work", and who has been agent-forwarding into a shared bastion for three
years. Every box they touch can borrow their identity and walk it anywhere they're trusted.

The `.env` that gets committed, noticed an hour later, and "fixed" by deleting the file in the
next commit. The key is still in the history. It is still in every fork. Nobody rotates it,
because the file is gone and the file being gone *feels* like it's gone.

The debug line. Somebody adds `set -x` to a CI job to see why it fails, the job prints the
token to the build log, the build log is world-readable inside the org, and it stays there for
the retention period. Which is forever, because nobody ever set one.

The export. They migrate password managers, drop a plaintext CSV of every credential they own
into `~/Downloads`, finish the import, and never delete it. I have found two-year-old exports
still sitting there. On laptops that travel.

The shell history. `curl -H "Authorization: Bearer sk-live-..."` — one command, permanently
recorded, synced to a dotfiles repo, and searchable by anyone who ever gets a shell.

The spreadsheet. Shared credentials in a workbook on a file share, justified because "it's
access controlled". The access control is a group that accumulated forty-one members over six
years and has never once been audited.

The rotation ticket that gets closed by generating a *new* key and never revoking the old one.
Now there are two valid credentials and only one of them is tracked.

The security professional who runs everything under `sudo` because it removes a class of
errors, and quietly leaves root-owned files scattered through their own home directory. The
same person who will `chmod 777` a directory at 2am to make a deploy go through and never
change it back.

Base64. Called encryption. In a design document. Approved.

And now, the new one: pasting an API key into a chat with an AI agent so it can help debug the
integration. The key is now in a transcript. The transcript is in a log. The log is in a
retention policy someone else owns.

None of these people are careless. They are busy, and every one of these is the path of least
resistance at the moment they take it. That is the actual problem — **the secure thing is
almost never the easy thing**, so under deadline the easy thing wins.

So the point of `secretsd` is not to lecture anyone. It is to make the secure path the
*shortest* path: generate the credential without ever seeing it, inject it into exactly one
process, hand an agent a key *name* instead of a key, and get told — every single launch, until
you deal with it — which of the above you are currently doing.

Because I was doing several of them. It found fourteen unpassphrased SSH keys on my own
machine the first time I ran it.

## What it does about it

Values are generated locally, encrypted at rest, and injected only into the child process that
needs them. **The key name is the most anyone — including the agent — ever learns.**

## What it looks like

```
  ⣿⣿⣿  S E C R E T S                                          notebook-01
  bridging the secure informational gap between man and machine
  ──────────────────────────────────────────────────────────────────────
  ▌ ⡏⣩⣍⢹  VAULTS ··························· 3 databases  ● 142 credentials
  ▌ ⣇⣙⣋⣸  encrypted databases, recipients, and backup policy

    ⠙⣦⣴⠋  WORKSPACE ····················· 7 projects  ● Claude Code 2.1.226
    ⣠⠟⠻⣄  launch a named session — clean, or scoped to one profile

    ⠀⣺⣗⠀  INBOX ···················· 2 unread  ● agent-authored credentials
    ⣾⠿⠿⣷  what an agent created for you, for which project, and why

    ⡏⠭⠭⢹  POSTURE ································ 21 findings  ● 15 critical
    ⠉⢯⡽⠉  common power-user exposures — reported every launch, fixed by you
  ──────────────────────────────────────────────────────────────────────
  ↑↓ move   ↵ open   / find   g generate   a audit   ? keys   q quit
```

Dot-matrix pictograms drawn as 8×8 braille bitmaps, a per-column gradient mask on the active
row, and a full-bleed layout that fills any terminal at any size. No emoji — emoji width varies
by terminal and font, and a single variation selector shifts an entire column.

---

## Modules

| | |
|---|---|
| **API** | tokens and service credentials — the flat key/value store |
| **Keys** | your real `~/.ssh` estate: fingerprints, which hosts use each key, passphrase state, agent state |
| **Certificates** | expiry **parsed from the certificate**, never a hand-typed date. Includes YubiKey PIV slots |
| **Machines** | a reader over `~/.ssh/config` with TCP-only reachability probes that never authenticate |
| **Auth Mapping** | how you authenticate to what — plaintext by design, so the access map is readable without decrypting |
| **Environments** | projects, where they live, how they're served and backed up. Seeds itself from what's discoverable |
| **Logins** | accounts, passwords, TOTP, recovery codes — encrypted, masked, never printed |
| **PII** | identity records, encrypted to **one** recipient by design |
| **Domains** | Cloudflare DNS with guarded writes: before/after diff, confirm, then re-read the zone to report what it *actually* holds |

Plus **YubiKey** (OATH codes, PIV slots, and moving a TOTP seed off disk onto hardware) and a
239-item **command palette** over every module at once.

---

## Expiry that comes to you

`secretsd expiring` is a correct report that is completely useless if you only think to run it
after the outage. So it runs on a schedule and comes to you instead — a desktop notification, a
written report, and a line on the dashboard the next time you open the program.

```sh
secretsd alerts            # the screen: counts, schedule, last check
secretsd alerts run        # what launchd calls, daily
secretsd alerts --json     # exit 2 if anything is expired, 1 if anything is due
```

It reads expiry from three places, because that is where expiry actually lives:

1. the `expires:` dates you recorded in the manifest
2. **the certificates themselves**, parsed from the PEM — no bookkeeping to forget
3. everything with **no recorded expiry at all**, reported as a finding rather than as silence

That third one is the whole point. On the machine this was written for, the manifest-only report
said *zero expired* while four DoD CA certificates on disk had been dead for up to 497 days.
Nothing was wrong with the report. It was answering a question about a file nobody had updated.

It will not rotate, renew, or delete anything. It tells you, and it keeps telling you.

---

## Why a note vault is part of this

Every strong development and security team I have worked with had the same thing in common, and
it was never the tooling budget. It was that they wrote things down. A vault of runbooks,
architecture notes, decision records, host inventories — Obsidian, a wiki, a pile of markdown in
git, it did not matter which. The teams that had one recovered from incidents in hours. The
teams that did not spent those hours reconstructing what past-them already knew.

But that knowledge base always has a hole in it, and the hole is always the same shape.

You write the runbook. It says "restore the database, then re-point the API at the new host."
And right where the credential belongs, you write one of three things: nothing, a placeholder
that rots, or — and I have seen this in genuinely good organisations — the actual secret,
because the runbook is useless without it and the vault is "internal anyway". Now your knowledge
base is a credential store with no encryption, no rotation, no audit, and full-text search.

`secretsd` is built to fill that hole from the other side.

**The directory tier is meant to be read.** Auth Mapping, Machines and Environments are
plaintext YAML by design. They hold *no* secret values — only the map: which host, which method,
which credential **by name**, where the project lives, how it is served, how it is backed up. You
can read your entire access topology, link it from a note, diff it, commit it, and never decrypt
anything. The dangerous half stays encrypted and separate.

**So a runbook can be complete without being dangerous.** The note says
`secretsd run --only PROD_DB_URL -- ./restore.sh`. That line is safe to write down, safe to
paste into a ticket, safe to hand to a colleague, and safe to leave in a repository. It is also
directly executable. The credential resolves at run time, in one child process, and never
appears in the document — or in your terminal.

**The agent reads the same note you do.** This is the part that matters now. You point Claude at
the runbook. It sees `PROD_DB_URL` — a name — and it can act on that name without the value ever
entering the conversation. When it needs a *new* credential it generates one into the vault and
records why, and that record shows up in your Inbox with the project and reason attached. The
knowledge base stays the source of truth for *how*, the vault stays the source of truth for
*what*, and the agent never becomes the transport between them.

**Sessions become part of the record too.** A named session maps back to its transcript, so a
note can reference the conversation where a decision was actually made — not a UUID nobody can
resolve six months later. Pair that with the broker and a year of scattered sessions can be
consolidated into one briefing you can file alongside the runbook.

Obsidian is the system that is wired today; Apple Notes, Notepad, CherryTree, Notion and Joplin
are listed in the pairing screen and honestly marked as not yet implemented. The pairing is
deliberately visible in the product so you can see what is real and what is roadmap.

## The agent story

**Provenance.** An agent that needs a credential calls
`secretsd record NAME --agent A --project P --reason "…"`. The value was generated locally and
encrypted; the agent knows only the name. You see it later in the **Inbox**, unread, with full
attribution: which agent, which project, what for.

**Named sessions.** Claude Code identifies sessions by UUID, and those UUIDs are what land in
your logs. The launcher **refuses to start without a human name** — it mints the UUID itself,
passes `--session-id` and `--name`, and records the mapping. Resume by name, forever.

**Adoption.** Sessions that already exist get named too. Claude writes an `ai-title` into most
transcripts, so adopting is usually one keypress.

**The broker.** `claude -p --resume <uuid>` answers *with that session's full history* — so two
finished sessions can genuinely be put in conversation. Merging runs three rounds: each states
its position blind, each then argues against the other's, and a neutral third instance writes a
consolidated brief. The result seeds a **new** session; the originals are never modified.

**The janitor.** The same mechanism turned on the whole estate: each session is asked, with its
own history in front of it, whether it's still worth keeping — `KEEP`, `ARCHIVE`, or `PURGE`,
with a reason. It only ever recommends.

---

## Security model

**Inject, never retrieve.** No command prints a secret value. `secretsd run -- cmd` decrypts
into one child process. The single deliberate exception is `copy`, which routes to the clipboard
and clears itself on a timer *and* on exit.

**Plaintext never touches disk.** Encrypted record stores are read through
`sops -d --output-type json` into a pipe and written through `sops set`. Bulk import merges in
memory and pipes straight into `sops --encrypt`. There is no decrypt-edit-reencrypt temp file.

**Warn, never rectify.** The posture engine detects the exposures power users actually
accumulate — SSH keys with no passphrase, orphan keys, `ForwardAgent`, stale config backups,
world-readable metadata, plaintext `.env` files beside code, credential-shaped lines in shell
history, recipient drift, undocumented credentials. It reports them **every launch until you
act**, and changes nothing on its own. Persistent nagging is the enforcement; the authority
stays with you.

The only things it hardens without asking are its own process — `umask 077`, core dumps
disabled, its own scratch directory — and it refuses to run as root.

**Nothing is called fixed without re-measuring.** Every fix re-checks the condition afterwards
and reports failure honestly rather than trusting an exit code.

---

## Install

Requires `bash` 4+, `sops`, `age`, `python3`, and `git`. Optional but recommended: `gum`
(nicer prompts), `jq` (Cloudflare), `ykman` (YubiKey), `openssl` (certificates, generation).

```sh
git clone https://github.com/Archn3m3sis/secretsd.git
cd secretsd
./install.sh
```

`install.sh` symlinks `secretsd` (and a `secrets` alias) into `~/.local/bin`, installs the zsh
completion, and asks where your data should live.

### Importing an existing manager

```sh
secretsd import      # Bitwarden · 1Password · KeePass/XC · Passbolt · pass
secretsd keychain    # macOS login keychain
```

Format is detected from the file's own structure, not its extension. A dry preview shows what
would be written — names and field types only, never a value.

The keychain importer is honest about what it costs you. Listing what is in there is free —
names are not secret, and no authorisation is required. **Reading a value is not free**: macOS
raises an allow-access dialog per item, because secretsd is not the app that stored it. That is
the keychain working correctly, so the importer is built around picking a handful rather than
approving fifty dialogs. Apple's own internals are hidden by default (53 of 165 items on a real
Mac); `KC_SHOW_SYSTEM=1` includes them. Nothing is ever removed from the keychain.

---

## Scripting it

Every read-only report has a `--json` form, and the flag works on either side of the subcommand.

```sh
secretsd names --json      # the inventory
secretsd doctor --json     # every health check, with its verdict
secretsd expiring --json   # dates, days remaining, and what has no date at all
secretsd posture --json    # security findings
secretsd sessions --json   # named Claude Code sessions
secretsd alerts --json     # the scheduled expiry scan
```

Exit codes are the CI contract: **0** clean, **1** warnings, **2** something critical or expired.
So a pipeline gate is one line:

```sh
secretsd doctor --json > health.json || echo "credential store needs attention"
```

**No `--json` output ever contains a credential value** — not truncated, not hashed, not "just the
first four characters". Names, dates, counts, and verdicts only. The test suite decrypts the
fixture store and greps every JSON output for every real value; finding one fails the build.

Each report has exactly one producer feeding both renderers, so the terminal view and the JSON
can never disagree about what was found.

---

## Data layout

Code and data are deliberately separate. Resolution order for the data root:

1. `$SECRETSD_HOME`
2. a path in `~/.config/secretsd/home`
3. `secrets/` beside the code (development layout)
4. `~/.local/share/secretsd`

```
<data root>/
  secrets/
    api-keys.enc.env      the API store
    domains/*.enc.yaml    encrypted record stores (logins, pii, certs…)
    directory/*.yaml      plaintext maps — no secret values, ever
    CREDENTIALS.yaml      what each credential permits and when it dies
    SESSIONS.yaml         human name → session UUID
    PROVENANCE.yaml       which agent created what, and why
  run-logs/               a timestamped line per mutating action
```

Only mutating actions are logged. Reads leave no trace by design.

---

## Status

Written for one person's real machine and hardened against the problems that machine actually
had. It is used daily, but it has one author and one production install — read the source
before you trust it with anything you cannot afford to lose. Issues and patches welcome.

Bash, ~12,000 lines, no runtime dependencies beyond the tools above.
52 tests, run on Linux and macOS in CI.

## License

MIT © Kyle Hurston
