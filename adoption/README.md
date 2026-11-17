# Adoption evidence (temporary)

This folder is temporary. It is deleted with `deploy/adoption/` once every unit has had its first run as a deployment stack.
A stack has no baseline before its first apply, so the first preview of a unit still lists differences that Azure reports
and a deployment does not change. `adoption.py` writes `deploy/adoption/<unit>.md` for every unit of `deploy/units.json`,
with the counts of the unit's preview and the reason for each record that is not NoChange. The approver of the unit's first
run reads that file beside the preview. A record the gate did not accept is listed first in its file. The tool is outside
the deploy path, reads saved files only and makes no Azure call. Each file ends with the unit's template and parameters
file and the SHA256 of their text. The plan of a unit's first run fails when the file is missing, when it says it is not
evidence, and when one of those values is not the value of the file in the commit being deployed, so the evidence always
belongs to the code that is deployed. Run the tool on the code the previews were taken from, again after every sweep and
after every change to a unit's template or parameters file, with the folder of saved previews and the folder of gate
results (`scripts/deploy-unit.ps1 -Unit <unit> -WhatIfJson <file>`, one `<unit>.txt` each).
`python adoption/adoption.py <sweep folder> <gate folder> --sweep "the read-only sweep of the estate of <date>"`
