# Evidence Reuse

Read this file if you want to reuse a baseline or mutation evidence instead of a new run. Reuse is optional.

## What may be reused

- [AGENTS.md](../../../../AGENTS.md#validation-and-review) limits the reuse of a baseline, and it requires new gates and a fresh verdict after a fix or a rollback. This file does not relax those rules.
- Mutation evidence MAY be reused while the candidate, the tests, the dependencies, the isolation and the provenance still match.

## Rules for every reuse

- Record the provenance that [What to record](#what-to-record) lists.
- If a relevant input changed, or you do not know whether it changed, run the affected checks again.
- A check that depends on the revision needs a new run when the commit metadata changes.

## What to record

Record these items in the working record:

- The revision that was tested originally, the commands, the results and the location of the evidence.
- A comparison of the relevant inputs: implementation, tests, dependencies on the call path, configuration, file modes, symlink targets and environment. Include the in-scope untracked inputs.
- The fingerprints of the tested inputs.
- The environment evidence that shows equivalence, without secrets. Include tool versions and dependency versions where they are relevant.

Never read ignored content or secrets to build this provenance.
