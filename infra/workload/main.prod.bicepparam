using './main.bicep'

param environmentName = 'prod'
param workloadName = 'hotelbooking'

param spokeVnetResourceId = '' // Provided at deploy time via --parameters override
param hubVnetResourceId = '' // Provided at deploy time via --parameters override
param acrResourceId = '' // Provided at deploy time from deploy-shared outputs
param acrLoginServer = '' // Provided at deploy time from deploy-shared outputs
