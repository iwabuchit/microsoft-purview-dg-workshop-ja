targetScope = 'resourceGroup'

// parameters
@description('Please specify a login name for the Azure SQL Server administrator. Default value: wssqladmin.')
param sqlServerAdminLogin string = 'wssqladmin'
@secure()
//@description('Please specify a password for the Azure SQL Server administrator. Default value: newGuid().')
//param sqlServerAdminPassword string = newGuid()
@description('Please specify a password for the Azure SQL Server administrator. Default value: PenApplePineapple!1')
param sqlServerAdminPassword string = 'PenApplePineapple!1'

// Variables
var tenantId = subscription().tenantId
var location = resourceGroup().location
var subscriptionId = subscription().subscriptionId
var resourceGroupName = resourceGroup().name
var rdPrefix = '/subscriptions/${subscriptionId}/providers/Microsoft.Authorization/roleDefinitions'
var role = {
  Owner: '${rdPrefix}/8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
  Contributor: '${rdPrefix}/b24988ac-6180-42a0-ab88-20f7382dd24c'
  StorageBlobDataReader: '${rdPrefix}/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  StorageBlobDataContributor: '${rdPrefix}/ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}
var prefix = 'pvws'
var suffix = substring(uniqueString(resourceGroup().id, deployment().name), 0, 5)

// Azure Storage Account (ADLS Gen2)
//resource storageAccount 'Microsoft.Storage/storageAccounts@2021-02-01' = {
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${prefix}${suffix}adls'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    isHnsEnabled: true
    allowBlobPublicAccess: true
    accessTier: 'Hot'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
  resource blobService 'blobServices' = {
    name: 'default'
    resource blobContainer 'containers' = {
      name: 'dataset'
      properties: {
        publicAccess: 'Blob'
      }
    }
  }
}

//Azure SQL Server
resource sqlsvr 'Microsoft.Sql/servers@2023-05-01-preview' = {
  name: '${prefix}${suffix}-sqlsvr'
  location: location
  properties: {
    administratorLogin: sqlServerAdminLogin
    administratorLoginPassword: sqlServerAdminPassword
    publicNetworkAccess: 'Enabled'
    // "administrators": {
    //   "administratorType": "ActiveDirectory",
    //   "principalType": "User",
    //   "login": "Takeshi.Iwabuchi@MngEnvMCAP554201.onmicrosoft.com",
    //   "sid": "921977e9-dc4b-45a3-9d6a-44b565e5d744",
    //   "tenantId": "110a9448-c121-4dc2-aa31-68a79012f8ae",
    //   "azureADOnlyAuthentication": true
    // },
  }
  resource firewall1 'firewallRules' = {
    name: 'allowAzure'
    properties: {
      startIpAddress: '0.0.0.0'
      endIpAddress: '0.0.0.0'
    }
  }
  resource firewall2 'firewallRules' = {
    name: 'allowAll'
    properties: {
      startIpAddress: '0.0.0.0'
      endIpAddress: '255.255.255.255'
    }
  }
}

//Azure SQL Database
resource sqldb 'Microsoft.Sql/servers/databases@2022-05-01-preview' = {
  parent: sqlsvr
  name: '${prefix}${suffix}-sqldb'
  location: location
  sku: {
    name: 'GP_S_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    catalogCollation: 'SQL_Latin1_General_CP1_CI_AS'
    autoPauseDelay: 60
    requestedBackupStorageRedundancy: 'Local'
    sampleName: 'AdventureWorksLT'
  }
}

resource dataFactory 'Microsoft.DataFactory/factories@2018-06-01' = {
  name: '${prefix}${suffix}-adf'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  dependsOn: [
    storageAccount, sqldb
  ]
  resource linkedServiceStorage 'linkedservices@2018-06-01' = {
    name: 'AzureDataLakeStorageLinkedService'
    properties: {
      type: 'AzureBlobFS'
      typeProperties: {
        //connectionString: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value}'
        url: storageAccount.properties.primaryEndpoints.dfs
      }
    }
  }
  resource linkedServiceSqlDatabase 'linkedservices@2018-06-01' = {
    name: 'AzureSqlDatabaseLinkedService'
    properties: {
      type: 'AzureSqlDatabase'
      typeProperties: {
        //connectionString: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value}'
        //sqlServerAdminLogin
        //connectionString: 'Server=tcp:${prefix}${suffix}-sqlsvr.database.windows.net,1433;Initial Catalog=${prefix}${suffix}sqldb;Encrypt=True;TrustServerCertificate=False;'
        connectionString: 'Server=tcp:${prefix}${suffix}-sqlsvr.database.windows.net,1433;Initial Catalog=${prefix}${suffix}-sqldb;Persist Security Info=False;User ID=${sqlServerAdminLogin};Password=${sqlServerAdminPassword};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=90;'
      }
    }
  }
  resource linkedServiceHttpGithub 'linkedservices@2018-06-01' = {
    name: 'HttpGithubLinkedService'
    properties: {
      type: 'HttpServer'
      typeProperties: {
        url: 'https://github.com/iwabuchit/microsoft-purview-dg-workshop-ja/raw/refs/heads/gh-pages/1.Setup/datasets/'
        authenticationType: 'Anonymous'
        enableServerCertificateValidation: 'true'
      }
    }
  }
  resource datasetHttpEC 'datasets@2018-06-01' = {
    name: 'Web_EC_Dataset'
    properties: {
      linkedServiceName: {
        referenceName: linkedServiceHttpGithub.name
        type: 'LinkedServiceReference'
      }
      parameters: {
        FileName: {
          type: 'String'
        }
      }
      annotations: []
      type: 'Parquet'
      typeProperties: {
        location: {
          type: 'HttpServerLocation'
          relativeUrl: {
            type: 'Expression'
            value: '@dataset().FileName'
          }
        }
        compressionCodec: 'snappy'
      }
      schema: []
    }
  }
  resource datasetAdlsParquetEC 'datasets@2018-06-01' = {
    name: 'ADLS_EC_Dataset'
    properties: {
      linkedServiceName: {
        referenceName: linkedServiceStorage.name
        type: 'LinkedServiceReference'
      }
      parameters: {
        FileName: {
          type: 'String'
        }
      }
      annotations: []
      type: 'Parquet'
      typeProperties: {
        location: {
          type: 'AzureBlobFSLocation'
          fileName: {
            type: 'Expression'
            value: '@dataset().FileName'
          }
          fileSystem: 'dataset'
        }
        compressionCodec: 'snappy'
      }
      schema: []
    }
  }
  resource datasetSqlTableEC 'datasets@2018-06-01' = {
    name: 'SQLDB_Transactions'
    properties: {
      linkedServiceName: {
        referenceName: linkedServiceSqlDatabase.name
        type: 'LinkedServiceReference'
      }
      annotations: []
      type: 'AzureSqlTable'
      schema: []
      typeProperties: {
        schema: 'Workshop'
        table: 'Transactions'
      }
    }
  }
  resource pipelineCreateAsetts 'pipelines@2018-06-01' = {
    name: 'Create Assets'
    properties: {
      activities: [
        {
          name: 'ForEach Files'
          type: 'ForEach'
          dependsOn: [
            {
              activity: 'Create Table'
              dependencyConditions: [
                'Succeeded'
              ]
            }
          ]
          userProperties: []
          typeProperties: {
            items: {
              value: '@variables(\'source_files\')'
              type: 'Expression'
            }
            activities: [
              {
                name: 'Github to Storage'
                type: 'Copy'
                dependsOn: []
                policy: {
                  timeout: '0.12:00:00'
                  retry: 0
                  retryIntervalInSeconds: 30
                  secureOutput: false
                  secureInput: false
                }
                userProperties: []
                typeProperties: {
                  source: {
                    type: 'ParquetSource'
                    storeSettings: {
                      type: 'HttpReadSettings'
                      requestMethod: 'GET'
                    }
                    formatSettings: {
                      type: 'ParquetReadSettings'
                    }
                  }
                  sink: {
                    type: 'ParquetSink'
                    storeSettings: {
                      type: 'AzureBlobFSWriteSettings'
                    }
                    formatSettings: {
                      type: 'ParquetWriteSettings'
                    }
                  }
                  enableStaging: false
                  translator: {
                    type: 'TabularTranslator'
                    typeConversion: true
                    typeConversionSettings: {
                      allowDataTruncation: true
                      treatBooleanAsNumber: false
                    }
                  }
                }
                inputs: [
                  {
                    //referenceName: 'Web_EC_Dataset'
                    referenceName: datasetHttpEC.name
                    type: 'DatasetReference'
                    parameters: {
                      FileName: {
                        value: '@item()'
                        type: 'Expression'
                      }
                    }
                  }
                ]
                outputs: [
                  {
                    //referenceName: 'ADLS_EC_Dataset'
                    referenceName: datasetAdlsParquetEC.name
                    type: 'DatasetReference'
                    parameters: {
                      FileName: {
                        value: '@item()'
                        type: 'Expression'
                      }
                    }
                  }
                ]
              }
              {
                name: 'Storage to SQLDB'
                type: 'Copy'
                dependsOn: [
                  {
                    activity: 'Github to Storage'
                    dependencyConditions: [
                      'Succeeded'
                    ]
                  }
                ]
                policy: {
                  timeout: '0.12:00:00'
                  retry: 0
                  retryIntervalInSeconds: 30
                  secureOutput: false
                  secureInput: false
                }
                userProperties: []
                typeProperties: {
                  source: {
                    type: 'ParquetSource'
                    storeSettings: {
                      type: 'AzureBlobFSReadSettings'
                      recursive: true
                      enablePartitionDiscovery: false
                    }
                    formatSettings: {
                      type: 'ParquetReadSettings'
                    }
                  }
                  sink: {
                    type: 'AzureSqlSink'
                    writeBehavior: 'insert'
                    sqlWriterUseTableLock: false
                    disableMetricsCollection: false
                  }
                  enableStaging: false
                  translator: {
                    type: 'TabularTranslator'
                    typeConversion: true
                    typeConversionSettings: {
                      allowDataTruncation: true
                      treatBooleanAsNumber: false
                    }
                  }
                }
                inputs: [
                  {
                    referenceName: 'ADLS_EC_Dataset'
                    type: 'DatasetReference'
                    parameters: {
                      FileName: {
                        value: '@item()'
                        type: 'Expression'
                      }
                    }
                  }
                ]
                outputs: [
                  {
                    referenceName: 'SQLDB_Transactions'
                    type: 'DatasetReference'
                  }
                ]
              }
            ]
          }
        }
        {
          name: 'Create Schema'
          type: 'Script'
          dependsOn: []
          policy: {
            timeout: '0.12:00:00'
            retry: 0
            retryIntervalInSeconds: 30
            secureOutput: false
            secureInput: false
          }
          userProperties: []
          linkedServiceName: {
            referenceName: 'AzureSqlDatabaseLinkedService'
            type: 'LinkedServiceReference'
          }
          typeProperties: {
            scripts: [
              {
                type: 'NonQuery'
                text: 'IF NOT EXISTS (\n    SELECT 1\n    FROM sys.schemas\n    WHERE name = \'Workshop\'\n)\nBEGIN\n    EXEC(\'CREATE SCHEMA Workshop\');\nEND'
              }
            ]
            scriptBlockExecutionTimeout: '02:00:00'
          }
        }
        {
          name: 'Create Table'
          type: 'Script'
          dependsOn: [
            {
              activity: 'Create Schema'
              dependencyConditions: [
                'Succeeded'
              ]
            }
          ]
          policy: {
            timeout: '0.12:00:00'
            retry: 0
            retryIntervalInSeconds: 30
            secureOutput: false
            secureInput: false
          }
          userProperties: []
          linkedServiceName: {
            referenceName: 'AzureSqlDatabaseLinkedService'
            type: 'LinkedServiceReference'
          }
          typeProperties: {
            scripts: [
              {
                type: 'NonQuery'
                text: 'IF OBJECT_ID(\'Workshop.Transactions\', \'U\') IS NOT NULL\nBEGIN\n    DROP TABLE Workshop.Transactions;\nEND\n\nCREATE TABLE Workshop.Transactions (\n    [Transaction_ID] bigint NULL,\n    [User_Name] nvarchar(100) NULL,\n    [Age] bigint NULL,\n    [Country] nvarchar(100) NULL,\n    [Product_Category] nvarchar(100) NULL,\n    [Purchase_Amount] float NULL,\n    [Payment_Method] nvarchar(100) NULL,\n    [Transaction_Date] datetime2 NULL\n);'
              }
            ]
            scriptBlockExecutionTimeout: '02:00:00'
          }
        }
        {
          name: 'Create View vw_TransactionAggregates'
          type: 'Script'
          dependsOn: [
            {
              activity: 'ForEach Files'
              dependencyConditions: [
                'Succeeded'
              ]
            }
          ]
          policy: {
            timeout: '0.12:00:00'
            retry: 0
            retryIntervalInSeconds: 30
            secureOutput: false
            secureInput: false
          }
          userProperties: []
          linkedServiceName: {
            referenceName: 'AzureSqlDatabaseLinkedService'
            type: 'LinkedServiceReference'
          }
          typeProperties: {
            scripts: [
              {
                type: 'NonQuery'
                text: '-- 国と商品カテゴリごとに購入金額の合計と平均を集計\nCREATE OR ALTER VIEW Workshop.vw_TransactionAggregates AS\nSELECT\n    Country,\n    Product_Category,\n    COUNT(Transaction_ID) AS Total_Transactions,\n    SUM(Purchase_Amount) AS Total_Purchase_Amount,\n    AVG(Purchase_Amount) AS Average_Purchase_Amount\nFROM\n    Workshop.Transactions\nGROUP BY\n    Country,\n    Product_Category\n;'
              }
            ]
            scriptBlockExecutionTimeout: '02:00:00'
          }
        }
        {
          name: 'Create View vw_PaymentMethodStats'
          type: 'Script'
          dependsOn: [
            {
              activity: 'ForEach Files'
              dependencyConditions: [
                'Succeeded'
              ]
            }
          ]
          policy: {
            timeout: '0.12:00:00'
            retry: 0
            retryIntervalInSeconds: 30
            secureOutput: false
            secureInput: false
          }
          userProperties: []
          linkedServiceName: {
            referenceName: 'AzureSqlDatabaseLinkedService'
            type: 'LinkedServiceReference'
          }
          typeProperties: {
            scripts: [
              {
                type: 'NonQuery'
                text: '-- 支払い方法ごとの取引件数と合計金額\nCREATE OR ALTER VIEW Workshop.vw_PaymentMethodStats AS\nSELECT\n    Payment_Method,\n    COUNT(Transaction_ID) AS Transaction_Count,\n    SUM(Purchase_Amount) AS Total_Purchase\nFROM\n    Workshop.Transactions\nGROUP BY\n    Payment_Method\n;'
              }
            ]
            scriptBlockExecutionTimeout: '02:00:00'
          }
        }
        {
          name: 'Create View vw_MonthlyPurchaseTrend'
          type: 'Script'
          dependsOn: [
            {
              activity: 'ForEach Files'
              dependencyConditions: [
                'Succeeded'
              ]
            }
          ]
          policy: {
            timeout: '0.12:00:00'
            retry: 0
            retryIntervalInSeconds: 30
            secureOutput: false
            secureInput: false
          }
          userProperties: []
          linkedServiceName: {
            referenceName: 'AzureSqlDatabaseLinkedService'
            type: 'LinkedServiceReference'
          }
          typeProperties: {
            scripts: [
              {
                type: 'NonQuery'
                text: '-- 月別の購入金額推移\nCREATE OR ALTER VIEW  Workshop.vw_MonthlyPurchaseTrend AS\nSELECT\n    FORMAT(Transaction_Date, \'yyyy-MM\') AS Transaction_Month,\n    SUM(Purchase_Amount) AS Monthly_Total,\n    COUNT(Transaction_ID) AS Monthly_Transactions\nFROM\n    Workshop.Transactions\nGROUP BY\n    FORMAT(Transaction_Date, \'yyyy-MM\')\n;'
              }
            ]
            scriptBlockExecutionTimeout: '02:00:00'
          }
        }
      ]
      variables: {
        source_files: {
          type: 'Array'
          defaultValue: [
            'ecommerce_transactions_germany.parquet'
            'ecommerce_transactions_japan.parquet'
            'ecommerce_transactions_usa.parquet'
          ]
        }
      }
      annotations: []
    }
  }

}

// Role Assignment: Who: Managed Identity (Data Factory); What: Storage Blob Data Contributor (RBAC role); Scope: ADLS Gen2 Storage Account
resource roleAssignment01 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('ra01${resourceGroupName}')
  scope: storageAccount
  properties: {
    principalId: dataFactory.identity.principalId
    roleDefinitionId: role['StorageBlobDataContributor']
    principalType: 'ServicePrincipal'
  }
}
