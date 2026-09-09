# Notes for agents working in this repository

## Commit attribution

Always include a `Co-Authored-By` trailer for the AI model contributing to a commit.
Use the exact runtime model identifier from the active session, including its version or
snapshot suffix when exposed; never substitute a generic name such as Codex or GPT, infer
the model from the configured default, or invent a version. For this session the trailer is:

```text
Co-Authored-By: gpt-6-astra <noreply@openai.com>
```

Verify the identifier again in future sessions. If multiple models contributed to the
committed work, include one trailer per distinct exact model identifier. This rule supersedes
older guidance against co-author trailers in project documents. Commit inside this
repository and do not push without asking the user.

## Tooling and temporary scripts are Scheme

Every tool, probe, generator, test harness and throwaway script is written in Scheme and run
with Chez (`scheme --script`, or `petite` where the compiler is not wanted). No Python, no
Perl, no other language, however small the job -- including one-off scripts in a scratch
directory that will be deleted afterwards. Shell is for invoking, not for logic: Makefile
recipes and the one-line command that runs a Scheme script are the extent of it. The
existing tools under `tools/`, `probes/` and `tests/` are the pattern to follow.
