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

## Installation

Install from the [PowerShell Gallery](https://www.powershellgallery.com/packages/gcpstools):

```powershell
Install-Module -Name gcpstools -Scope CurrentUser
```

`-Scope CurrentUser` installs into your user profile and does not require an
elevated (admin) session. Omit it to install for all users (requires admin).

## Usage

```powershell
# Import the module
Import-Module ./src/gcpstools

# Run tests
./build.ps1 -Test
```
