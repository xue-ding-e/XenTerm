function Get-MsiProperty([object]$Database, [string]$Name) {
    $view = $Database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'")
    $row = $null
    try {
        $null = $view.Execute()
        $row = $view.Fetch()
        if (-not $row) { throw "Missing MSI property $Name" }
        return [string]$row.StringData(1)
    } finally {
        try { $null = $view.Close() } finally {
        if ($null -ne $row -and [Runtime.InteropServices.Marshal]::IsComObject($row)) {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($row) | Out-Null
        }
        if ([Runtime.InteropServices.Marshal]::IsComObject($view)) {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) | Out-Null
        }
        }
    }
}
