"""Reject accidental private data in source and git author metadata."""
import pathlib, re, subprocess, sys
root = pathlib.Path(".")
failures = []
for path in root.rglob("*"):
    if not path.is_file() or any(p in {".git", "build", "DerivedData"} for p in path.parts):
        continue
    if path.suffix.lower() in {".ipa", ".p12", ".mobileprovision", ".key"}:
        failures.append(str(path) + ": filtype skal ikke ligge i repo")
    if path.suffix.lower() not in {".swift", ".md", ".yml", ".py", ".xcconfig", ".gitignore"}:
        continue
    text = path.read_text(encoding="utf-8")
    patterns = [r"AIza[0-9A-Za-z_-]{30,}", r"gh[pousr]_[0-9A-Za-z]{30,}",
                r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
                r"[0-9]{5,}-[A-Za-z0-9_-]{10,}\.apps\.googleusercontent\.com"]
    if any(re.search(p, text) for p in patterns):
        failures.append(str(path) + ": mulig hemmelighed eller indlejret klient-id")
    emails = re.findall(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", text)
    if any(not email.endswith(("@users.noreply.github.com", "@noreply.github.com")) for email in emails):
        failures.append(str(path) + ": mulig privat mailadresse")
# Only the checkout history is inspected, never system git config or credentials.
emails = subprocess.check_output(["git", "log", "--format=%ae%n%ce"], text=True).splitlines()
if any(email and not email.endswith(("@users.noreply.github.com", "@noreply.github.com", "@github.com")) for email in emails):
    failures.append("Git-historikken indeholder en ikke-noreply mailadresse")
if failures:
    print("\n".join(failures))
    sys.exit(1)
print("Privatlivskontrol bestået: ingen indlejrede nøgler, klient-id'er eller private mailadresser fundet.")
