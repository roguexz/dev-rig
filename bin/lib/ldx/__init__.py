"""ldx internal python package.

Stdlib-only code shared by the ldx command scripts. Bash commands invoke it
via ``PYTHONPATH=$LDX_HOME/bin/lib python3 -m ldx.<module>``; the shell keeps
the CLI glue (kubectl/helm/jq calls, flags, prompts) and python owns the
parsing/assembly of structured data (JSON/JSONC/YAML/HCL rendering).
"""
