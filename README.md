# gcpstools

Glenn's custom PowerShell tools module.

## Structure

```
gcpstools/
├── .github/workflows/publish.yml   # CI/CD for PowerShell Gallery
├── src/gcpstools/
│   ├── Private/                    # Internal helper functions
│   ├── Public/                     # Exported functions
│   ├── gcpstools.psd1              # Module Manifest
│   └── gcpstools.psm1              # Root Module Script
├── tests/                          # Pester tests
├── build.ps1                       # Local build/test script
├── CHANGELOG.md
├── LICENSE
└── README.md
```

## Usage

```powershell
# Import the module
Import-Module ./src/gcpstools

# Run tests
./build.ps1 -Test
```
