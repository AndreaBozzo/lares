#!/usr/bin/env python3
"""Static check: does any script read a variable nothing ever sets?

This exists because `${LARES_DIR}` once reached backup.sh while nothing defined
it, and under `set -u` that killed every scheduled backup before it wrote a
byte. The first CI check written for it was vacuous -- it ran the script with an
empty environment, so the script exited at its own env-file check long before
reaching the interesting code, and passed regardless.

So: check statically instead. A variable read by a script must be one of

  1. assigned in that same script,
  2. declared in .env.example (the repo's config contract), or
  3. supplied by /etc/lares/*.env (the secrets contract, listed below), or
  4. a shell builtin/special.

Anything else is a variable that will be empty, or fatal under `set -u`.
Exit status is the number of problems found.
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# Supplied at runtime by root-only files that are deliberately not in the repo.
SECRETS_CONTRACT = {
    "RESTIC_REPOSITORY", "RESTIC_PASSWORD",
    "B2_ACCOUNT_ID", "B2_ACCOUNT_KEY",
    "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
    "UPTIME_PUSH_URL", "NTFY_TOPIC", "NTFY_URL", "NTFY_INTERNAL_URL",
    "KUMA_URL", "KUMA_USERNAME", "KUMA_PASSWORD",
}

SHELL_BUILTINS = {
    "HOME", "PATH", "USER", "SHELL", "PWD", "OLDPWD", "IFS", "PS1", "PS2",
    "LINENO", "RANDOM", "SECONDS", "HOSTNAME", "EDITOR", "TERM", "LANG",
    "BASH_SOURCE", "FUNCNAME", "PIPESTATUS", "REPLY", "OPTARG", "OPTIND",
    "DEBIAN_FRONTEND", "TMPDIR",
}


def declared_in_env_example() -> set:
    f = REPO / ".env.example"
    if not f.exists():
        return set()
    return {
        line.split("=", 1)[0].strip()
        for line in f.read_text(encoding="utf-8").splitlines()
        if "=" in line and not line.lstrip().startswith("#")
    }


def assigned_in(text: str) -> set:
    """Names the script itself sets, by any mechanism bash offers."""
    names = set()
    # Any NAME= that is a plausible assignment, wherever it appears: start of
    # line, after `;` (PASS=0; FAIL=0), inside `if VAR=$(...)`, and so on.
    # Excludes $VAR= and == comparisons.
    names |= set(re.findall(r"(?<![$\w])([A-Z_][A-Z0-9_]*)=(?!=)", text))
    names |= set(re.findall(r'^\s*:\s*"?\$\{([A-Z_][A-Z0-9_]*):?=', text, re.M))  # : "${VAR:=x}"
    names |= set(re.findall(r"\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b", text))     # for VAR in
    names |= set(re.findall(r"\bread\s+(?:-r\s+)?([A-Za-z_][A-Za-z0-9_]*)", text)) # read VAR
    names |= set(re.findall(r"\blocal\s+([A-Za-z_][A-Za-z0-9_]*)", text))
    names |= set(re.findall(r"\bexport\s+([A-Z_][A-Z0-9_]*)", text))
    names |= set(re.findall(r"\bglobal\s+([A-Z_][A-Z0-9_]*)", text))
    return names


def read_in(text: str) -> set:
    """Uppercase variables the script reads, ignoring ones with a default."""
    names = set()
    # ${VAR} and ${VAR...} -- but NOT ${VAR:-x} / ${VAR:=x}, which are safe.
    for m in re.finditer(r"\$\{([A-Z_][A-Z0-9_]*)([^}]*)\}", text):
        if not m.group(2).startswith((":-", ":=", ":?", ":+", "-", "=", "+")):
            names.add(m.group(1))
    names |= set(re.findall(r"\$([A-Z_][A-Z0-9_]*)\b", text))
    return names


def main() -> int:
    contract = declared_in_env_example() | SECRETS_CONTRACT | SHELL_BUILTINS
    problems = 0
    for script in sorted((REPO / "scripts").glob("*.sh")):
        text = script.read_text(encoding="utf-8")
        # Strip comments: a comment describing the bug is not the bug.
        code = "\n".join(re.sub(r"(?<!\\)#.*$", "", ln) for ln in text.splitlines())
        unknown = read_in(code) - assigned_in(code) - contract
        for name in sorted(unknown):
            print(f"  {script.relative_to(REPO)}: reads ${name}, "
                  f"which nothing assigns and .env.example does not declare")
            problems += 1
    if problems:
        print(f"\n{problems} unbound-variable risk(s). Under `set -u` these are fatal.")
    else:
        print("no unbound-variable risks")
    return problems


if __name__ == "__main__":
    sys.exit(main())
