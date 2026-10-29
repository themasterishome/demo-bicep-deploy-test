// The empty template of the pilot unit, pilot-empty-rg in deploy/units.json (wave 0, disabled until IT approves
// it). It deploys into rg-demo-pilot, an empty resource group in the demo subscription that IT creates
// for the pilot alone. It declares nothing, so an Incremental deployment of it changes no resource. In Incremental mode Azure
// writes what a template declares and leaves everything else in the group as it is. The pilot only proves the
// deployment path end to end: the identity, its roles, the approval gate and the evidence capture. It has not
// been deployed yet. Its what-if returns no records, which the gate passes.
// Keep this file empty. A resource added here would be written into a production resource group by the first
// unit IT deploys.
targetScope = 'resourceGroup'
