def wh --env [] {
  while (true) {
      let $nav_file = ".fastnav-wormhole"
      let $dirty_nav_state = (($nav_file | path type) == file)
      if ($dirty_nav_state) {
          print -e $"($nav_file) exists already! Cleaning up!"
          rm $nav_file #clean up if there was something left before
      }
    
      wormhole
      let $target_path = open $nav_file
      let $target_type = ($target_path | path type)    
      
      rm $nav_file # clean up
      if ($target_type == dir) {
          cd $target_path
          break
      } else if ($target_type == file) {
          start $target_path # open with default app
          cd ($target_path | path expand | path dirname) # change to target directory to reopen wormhole there afterwards
      } else {
          print -e "Invalid Path"
          break
      }
  } 
} 
