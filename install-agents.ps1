$agentDirs = @("design", "engineering", "game-development", "marketing", "paid-media", "sales", "product", "project-management", "testing", "support", "spatial-computing", "specialized")
$repoRoot = "C:\Users\H2R\Documents\Default Project\agency-agents"
$destDir = "C:\Users\H2R\Documents\Default Project\.opencode\agents"

if (-not (Test-Path -Path $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

$colorMap = @{
    "cyan" = "#00FFFF"; "blue" = "#3498DB"; "green" = "#2ECC71"; "red" = "#E74C3C";
    "purple" = "#9B59B6"; "orange" = "#F39C12"; "teal" = "#008080"; "indigo" = "#6366F1";
    "pink" = "#E84393"; "gold" = "#EAB308"; "amber" = "#F59E0B"; "neon-green" = "#10B981";
    "neon-cyan" = "#06B6D4"; "metallic-blue" = "#3B82F6"; "yellow" = "#EAB308";
    "violet" = "#8B5CF6"; "rose" = "#F43F5E"; "lime" = "#84CC16"; "gray" = "#6B7280";
    "fuchsia" = "#D946EF"
}

$count = 0

foreach ($dir in $agentDirs) {
    $dirPath = Join-Path -Path $repoRoot -ChildPath $dir
    if (Test-Path -Path $dirPath) {
        $files = Get-ChildItem -Path $dirPath -Filter "*.md" -File
        foreach ($file in $files) {
            $content = Get-Content -Path $file.FullName -Raw
            # Simple frontmatter extraction
            $parts = $content -split "---", 3
            if ($parts.Count -ge 3) {
                $frontmatter = $parts[1]
                $body = $parts[2]

                $name = ""
                $description = ""
                $color = "#6B7280" # Default

                $lines = $frontmatter -split "`n"
                foreach ($line in $lines) {
                    if ($line -match "^\s*name:\s*(.*)") { $name = $matches[1].Trim() }
                    if ($line -match "^\s*description:\s*(.*)") { $description = $matches[1].Trim() }
                    if ($line -match "^\s*color:\s*(.*)") { $color = $matches[1].Trim() }
                }

                if ([string]::IsNullOrWhiteSpace($name)) { continue }

                # Resolve color
                $resolvedColor = $color
                if ($colorMap.ContainsKey($color.ToLower())) {
                    $resolvedColor = $colorMap[$color.ToLower()]
                } elseif ($color -notmatch "^#[0-9A-Fa-f]{6}$") {
                    $resolvedColor = "#6B7280"
                }

                # Slugify name
                $slug = $name.ToLower() -replace "[^a-z0-9]", "-" -replace "--+", "-" -replace "^-|-$", ""

                $outFile = Join-Path -Path $destDir -ChildPath "$slug.md"
                $outContent = "---`nname: $name`ndescription: $description`nmode: subagent`ncolor: '$resolvedColor'`n---`n$body"
                Set-Content -Path $outFile -Value $outContent -Encoding UTF8
                $count++
            }
        }
    }
}

Write-Host "Instalacion completada. $count agentes instalados en $destDir"
