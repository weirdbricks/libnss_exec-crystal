#!/bin/bash
# /sbin/nss_exec - Example NSS script

COMMAND="$1"
ARGUMENT="$2"

case "$COMMAND" in
  # Password database
  setpwent)
    # Reset enumeration
    exit 0
    ;;
  
  getpwent)
    # Return user entry by index ($ARGUMENT)
    # Format: name:passwd:uid:gid:gecos:dir:shell
    if [ "$ARGUMENT" = "0" ]; then
      echo "testuser:x:1000:1000:Test User:/home/testuser:/bin/bash"
      exit 0
    fi
    exit 1  # No more entries
    ;;
  
  getpwnam)
    # Look up user by name ($ARGUMENT)
    if [ "$ARGUMENT" = "testuser" ]; then
      echo "testuser:x:1000:1000:Test User:/home/testuser:/bin/bash"
      exit 0
    fi
    exit 1  # User not found
    ;;
  
  getpwuid)
    # Look up user by UID ($ARGUMENT)
    if [ "$ARGUMENT" = "1000" ]; then
      echo "testuser:x:1000:1000:Test User:/home/testuser:/bin/bash"
      exit 0
    fi
    exit 1
    ;;
  
  # Group database
  setgrent)
    exit 0
    ;;
  
  getgrent)
    if [ "$ARGUMENT" = "0" ]; then
      echo "testgroup:x:1000:testuser"
      exit 0
    fi
    exit 1
    ;;
  
  getgrnam)
    if [ "$ARGUMENT" = "testgroup" ]; then
      echo "testgroup:x:1000:testuser,otheruser"
      exit 0
    fi
    exit 1
    ;;
  
  getgrgid)
    if [ "$ARGUMENT" = "1000" ]; then
      echo "testgroup:x:1000:testuser"
      exit 0
    fi
    exit 1
    ;;
  
  # Shadow database (requires root)
  setspent)
    exit 0
    ;;
  
  getspent)
    if [ "$ARGUMENT" = "0" ]; then
      echo "testuser:!:18000:0:99999:7:::"
      exit 0
    fi
    exit 1
    ;;
  
  getspnam)
    if [ "$ARGUMENT" = "testuser" ]; then
      echo "testuser:!:18000:0:99999:7:::"
      exit 0
    fi
    exit 1
    ;;
  
  *)
    exit 3  # Unknown command
    ;;
esac
