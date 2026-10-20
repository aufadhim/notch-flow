#!/usr/bin/env python3
"""Send status or wrap an explicitly supplied Terminal command."""
import argparse
import subprocess
import sys
import uuid
from urllib.parse import urlencode


def send(**fields):
    url = "notchflow://activity?" + urlencode(fields)
    subprocess.run(["/usr/bin/open", "-g", "-a", "/Applications/NotchFlow.app", url], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    update = commands.add_parser("update")
    update.add_argument("id")
    update.add_argument("--title", required=True)
    update.add_argument("--detail", default="")
    update.add_argument("--progress", type=float)
    update.add_argument("--status", choices=["running", "done", "failed"], default="running")
    dismiss = commands.add_parser("dismiss")
    dismiss.add_argument("id")
    run = commands.add_parser("run")
    run.add_argument("--title", default="Terminal task")
    run.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == "dismiss":
        send(id=args.id, action="dismiss")
    elif args.action == "update":
        fields = dict(id=args.id, title=args.title, detail=args.detail, status=args.status)
        if args.progress is not None:
            if not 0 <= args.progress <= 1:
                parser.error("--progress must be between 0 and 1")
            fields["progress"] = args.progress
        send(**fields)
    else:
        command = args.command
        if command and command[0] == "--":
            command = command[1:]
        if not command:
            parser.error("run requires a command after --")
        identifier = str(uuid.uuid4())
        send(id=identifier, title=args.title, status="running")
        try:
            result = subprocess.run(command)
            code = result.returncode
        except KeyboardInterrupt:
            code = 130
        except OSError as error:
            print(error, file=sys.stderr)
            code = 127
        send(id=identifier, title=args.title, status="done" if code == 0 else "failed",
             detail="Completed" if code == 0 else "Exit status " + str(code))
        return code if code >= 0 else 128 - code
    return 0


if __name__ == "__main__":
    sys.exit(main())
