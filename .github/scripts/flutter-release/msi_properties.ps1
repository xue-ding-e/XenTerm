function Get-MsiProperty([object]$Database, [string]$Name) {
    $view = $Database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'")
    $null = $view.Execute()
    try {
        $row = $view.Fetch()
        if (-not $row) { throw "Missing MSI property $Name" }
        return [string]$row.StringData(1)
    } finally {
        $null = $view.Close()
    }
}
