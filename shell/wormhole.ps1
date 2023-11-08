
while($true) {
    $nav_file = ".fastnav-wormhole"
    $dirty_nav_state =  Test-Path $nav_file -PathType Leaf
    if($dirty_nav_state)
    {
        Write-Warning "$nav_file exists already! Cleaning up!"
        Remove-Item $nav_file #clean up if there was something left before
    }
    
    wormhole.exe
    $target_path = Get-Content .\.fastnav-wormhole
    $is_folder = Test-Path $target_path -PathType Container
    $is_file = Test-Path $target_path -PathType Leaf
    
    Remove-Item $nav_file
    if ($is_folder){
        Set-Location $target_path
        break
    }
    elseif ($is_file){
        Invoke-Item $target_path # open with default app
        Set-Location (get-item $target_path).Directory # change to target directory to reopen wormhole there afterwards
    }
    else {
        Write-Error "Invalid Path"
        break
    }
}