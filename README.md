# zoneupdate
Tool for bind authoritative name servers.
zoneupdate is a tool written in shell language (bash). 
It finds updated zonefiles, raises the serial and reloads them. 
It also checks for errors in the bind application logfile.

$ zoneupdate -?
Usage: zoneupdate [OPTION]... [FILE]...

This tool finds updated zonefiles, raises the serial and reloads them. -By default after interactive confirmation.

  -h -?     shows this help info.

  -b        headless bulk mode - finds multiple zonefiles, updates the serials and reloads them. -also overrides '-f' function

  -x 		    headless single file mode - tries to find the last modified zonefile and perform a reload. -also overrides '-f' function

  -d 		    runs the tool in dev mode - nothing is being modified only print what normally would be done. -this argument should preceed anything else.

  -f		    specify zonefile manually - always use this flag as the last argument
