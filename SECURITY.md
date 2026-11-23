# Security

ReGlass holds sensitive things: the key that owns your glasses, your Claude and ElevenLabs keys, a Meta sign-in, and
your notes and chats. Please report security problems privately.

## Report privately

Use GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a
vulnerability**. Only the maintainers see the report.

Don't open a public issue, pull request or discussion for a security problem.

Please include:

- what the problem is, and what someone could do with it;
- the steps to reproduce it;
- the ReGlass version or commit, your iPhone model and iOS version, and the glasses model and firmware;
- whether you have told anyone else.

ReGlass is a volunteer project. We'll answer as soon as we can, and tell you what we plan to do. There is no bug
bounty.

## In scope

- The ReGlass app, the widget extension, `ReGlassKit`, `ReGlassAssistant` and `tools/meta-tokens/`.
- For example:
  - a key, token, owner key or Meta sign-in leaving the iPhone, being stored unprotected, or reaching a log;
  - personal content (what was said, notes, titles) reaching a log or a service it shouldn't;
  - another app, website or nearby device making ReGlass act, or controlling the glasses through it;
  - the token helper writing secrets where others can read them, or trusting an app copy it shouldn't;
  - ReGlass sending something to the glasses that their owner didn't ask for.

## Out of scope

- Problems in Meta's, Apple's, Anthropic's or ElevenLabs' own services, apps or firmware. Report those to them.
- The risks of using Meta AI's client tokens, which are described in
  [docs/META-CREDENTIALS.md](docs/META-CREDENTIALS.md).
- Attacks that need an unlocked iPhone in someone else's hands, or a jailbroken iPhone.

## Never post these in public

Not in issues, pull requests, discussions, screenshots or chats, and not "just masked a little":

- **Meta tokens:** the `HW|`, `AR|` and `FRL|` client tokens, or `Secrets.xcconfig`.
- **Meta account details:** your email, sign-in codes, or anything from the sign-in screens.
- **Keys:** Claude or ElevenLabs keys. If one leaks, revoke it with that service at once.
- **Your glasses' serial number or other device identifiers.**
- **Logs with personal data.** The activity log can contain short device identifiers. Read every line before
  sharing and remove identifiers and anything personal. [Collecting and sharing logs](docs/TROUBLESHOOTING.md#read-and-share-the-activity-log)
- **Recordings of anyone** who hasn't agreed to it.

If you posted something by mistake, delete it, rotate what you can, and tell us privately.
