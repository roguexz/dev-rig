"""Coding-harness adapters.

One module per harness (opencode, ...). Each exposes the same CLI shape so
the bash commands stay thin: data comes in via stdin/env, rendered config
goes to stdout. Shared gateway/cluster reads live in ldx.gateway.
"""
