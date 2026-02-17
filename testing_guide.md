# Testing Guide for libnss_exec Crystal Port

This guide will help you test the Crystal implementation thoroughly before deploying to production.

## Prerequisites

```bash
# Install Crystal
curl -fsSL https://crystal-lang.org/install.sh | sudo bash

# Verify installation
crystal --version  # Should show 1.x.x or higher

# Clone or navigate to the project directory
cd libnss_exec_crystal
```

## Phase 1: Compilation Testing

### Step 1.1: Check Syntax
```bash
# Quick syntax check (no compilation)
make check

# Auto-format code to Crystal style
make format
```

**Expected**: No errors. If you see formatting issues, run `make format` to fix them.

### Step 1.2: Build the Library
```bash
# Build without installing
make

# Look for the output file
ls -lh libnss_exec.so.2
```

**Expected**: Should see a file around 1-3 MB (Crystal libraries are larger than C).

**Common Issues**:
- **"crystal: command not found"** → Install Crystal
- **"undefined reference"** → Check that all `.cr` files are present
- **Type errors** → Copy the error and we'll fix it

## Phase 2: Standalone Testing (No NSS Integration)

### Step 2.1: Create a Test Script

Create `/tmp/nss_exec_test` (not `/sbin/nss_exec` yet):

```bash
#!/bin/bash
# Temporary test script

case "$1" in
    getpwnam)
        if [ "$2" = "testuser" ]; then
            echo "testuser:x:5000:5000:Test User:/home/testuser:/bin/bash"
            exit 0
        fi
        exit 1
        ;;
    getpwuid)
        if [ "$2" = "5000" ]; then
            echo "testuser:x:5000:5000:Test User:/home/testuser:/bin/bash"
            exit 0
        fi
        exit 1
        ;;
    getgrnam)
        if [ "$2" = "testgroup" ]; then
            echo "testgroup:x:5000:testuser,alice"
            exit 0
        fi
        exit 1
        ;;
    *)
        echo "Unknown: $1 $2" >&2
        exit 3
        ;;
esac
```

Make it executable:
```bash
chmod +x /tmp/nss_exec_test
```

### Step 2.2: Test Script Directly

```bash
# Test the script works
/tmp/nss_exec_test getpwnam testuser
# Expected: testuser:x:5000:5000:Test User:/home/testuser:/bin/bash

/tmp/nss_exec_test getpwuid 5000
# Expected: testuser:x:5000:5000:Test User:/home/testuser:/bin/bash

/tmp/nss_exec_test getgrnam testgroup
# Expected: testgroup:x:5000:testuser,alice
```

### Step 2.3: Build and Run Crystal Test Program

First, **temporarily** modify `nss_exec.cr` to use the test script:

```crystal
# Change this line temporarily:
NSS_EXEC_SCRIPT = "/tmp/nss_exec_test"  # Instead of /sbin/nss_exec
```

Build and run:
```bash
make test
./test_nss_exec
```

**Expected Output**:
```
==============================================================
NSS Exec Crystal Implementation - Test Suite
==============================================================

Testing direct script execution...
  Command: getpwnam testuser
  Status:  SUCCESS
  Output:  testuser:x:5000:5000:Test User:/home/testuser:/bin/bash

Testing getpwnam for 'testuser'...
  Found user:
    Username: testuser
    UID:      5000
    GID:      5000
    GECOS:    Test User
    Home:     /home/testuser
    Shell:    /bin/bash

...
```

**If it crashes or fails**:
1. Copy the error message
2. Check that the script output format is exactly: `name:pass:uid:gid:gecos:dir:shell`
3. Make sure there are NO trailing spaces or newlines in script output

### Step 2.4: Test Buffer Handling

Add this to your test script to test large output:

```bash
getpwnam_large)
    # Test with long strings
    name="verylongusernamethatisverylong"
    echo "$name:x:5000:5000:This is a very long GECOS field with lots of information:/home/$name:/bin/bash"
    exit 0
    ;;
```

Test:
```bash
/tmp/nss_exec_test getpwnam_large
```

**Expected**: Should handle it fine. If you get buffer errors, the BufferWriter is working correctly.

## Phase 3: NSS Integration Testing

⚠️ **Warning**: This modifies system authentication. Only proceed if you understand the risks.

### Step 3.1: Install the Library

```bash
# Install to system
sudo make install

# Verify installation
ls -l /usr/lib/libnss_exec.so.2

# Check library exports (optional)
nm -D /usr/lib/libnss_exec.so.2 | grep _nss_exec
```

**Expected**: Should see functions like `_nss_exec_getpwnam_r`, `_nss_exec_getgrent_r`, etc.

### Step 3.2: Deploy Production Script

Now create the real script:

```bash
sudo cp /tmp/nss_exec_test /sbin/nss_exec
sudo chmod +x /sbin/nss_exec

# Test it
sudo /sbin/nss_exec getpwnam testuser
```

### Step 3.3: Configure NSS (Carefully!)

**IMPORTANT**: Keep a root shell open as backup!

```bash
# Open a root shell in another terminal (KEEP IT OPEN!)
sudo -i

# In your main terminal, backup nsswitch.conf
sudo cp /etc/nsswitch.conf /etc/nsswitch.conf.backup

# Edit carefully
sudo vi /etc/nsswitch.conf
```

Add `exec` AFTER existing sources (not before!):
```
passwd:     files systemd exec
group:      files systemd exec
shadow:     files exec
```

**Why this order matters**: 
- `files` first ensures system users still work
- `exec` last means it's only called if user not found in files

### Step 3.4: Test with getent

In your **non-root** terminal (while keeping root shell open):

```bash
# Test user lookup
getent passwd testuser

# Expected: testuser:x:5000:5000:Test User:/home/testuser:/bin/bash

# Test UID lookup  
getent passwd 5000

# Test group
getent group testgroup

# Test that system users still work!
getent passwd root
getent passwd $(whoami)
```

**If anything breaks**:
1. Go to your root shell
2. Run: `cp /etc/nsswitch.conf.backup /etc/nsswitch.conf`
3. Problem solved!

### Step 3.5: Test with System Tools

```bash
# Test id command
id testuser

# Test user switching (in root shell)
sudo su - testuser  # Should fail (no real home dir)
# But the lookup should work: "No directory, logging in with HOME=/"

# Check authentication logs
sudo tail -f /var/log/auth.log  # or /var/log/secure
# Run: getent passwd testuser
# Should see NSS queries in logs
```

## Phase 4: Stress Testing

### Test 4.1: Enumeration Performance

```bash
# Time full enumeration (may be slow without caching!)
time getent passwd

# Count entries
getent passwd | wc -l
```

### Test 4.2: Concurrent Access

```bash
# Test thread safety (run in multiple terminals simultaneously)
for i in {1..100}; do getent passwd testuser; done

# In another terminal at the same time:
for i in {1..100}; do getent group testgroup; done
```

**Expected**: No crashes, no corruption, consistent results.

### Test 4.3: Error Handling

Test the script failing:

```bash
# Make script return error
sudo vi /sbin/nss_exec
# Add a case that exits with 1, 2, 3

getent passwd nonexistent  # Should return nothing (NOTFOUND)
getent passwd slow_user    # Should retry if returns 2 (TRYAGAIN)
```

## Phase 5: Performance Optimization

### Install nscd (Name Service Cache Daemon)

```bash
# Install caching daemon
sudo apt-get install nscd  # Ubuntu/Debian
sudo dnf install nscd      # Fedora/RHEL

# Enable and start
sudo systemctl enable nscd
sudo systemctl start nscd

# Check status
sudo systemctl status nscd
```

### Test Cache Performance

```bash
# First call (uncached)
time getent passwd testuser

# Second call (cached)
time getent passwd testuser  # Should be MUCH faster

# Clear cache to test again
sudo nscd -i passwd
```

### Monitor Cache Stats

```bash
# Watch cache statistics
watch -n 1 'sudo nscd -g'
```

## Phase 6: Security Testing

### Test 6.1: Script Injection

Try to inject commands:

```bash
# These should NOT execute commands
getent passwd 'testuser; ls'
getent passwd 'testuser`whoami`'
getent passwd '$( whoami )'
```

**Expected**: Crystal's `Process.quote` should prevent injection.

### Test 6.2: Buffer Overflow

Test with huge inputs:

```bash
# Generate very long username
getent passwd $(python3 -c 'print("A" * 10000)')
```

**Expected**: Should fail gracefully, not crash.

### Test 6.3: Privilege Checks

Shadow passwords require root:

```bash
# As regular user (should fail)
getent shadow testuser

# As root (should work)
sudo getent shadow testuser
```

## Phase 7: Production Readiness Checklist

Before deploying to production:

- [ ] All tests pass
- [ ] No crashes under concurrent load
- [ ] System users still work (getent passwd root)
- [ ] NSS caching (nscd) is enabled
- [ ] Script performance < 100ms per call
- [ ] Backup of /etc/nsswitch.conf exists
- [ ] Monitoring/logging is set up
- [ ] SELinux/AppArmor rules configured (if applicable)
- [ ] Tested on staging environment first

## Troubleshooting

### Problem: "Library not found"
```bash
# Check library path
ldconfig -p | grep nss_exec

# If not found, run:
sudo ldconfig
```

### Problem: Functions not exported
```bash
# Check symbols
nm -D /usr/lib/libnss_exec.so.2 | grep _nss_exec

# Should see all the functions like _nss_exec_getpwnam_r
```

### Problem: SELinux denials
```bash
# Check for denials
sudo ausearch -m avc -ts recent

# Temporarily disable SELinux for testing
sudo setenforce 0

# Re-enable when done
sudo setenforce 1
```

### Problem: Slow performance
```bash
# Install and enable nscd
sudo apt-get install nscd
sudo systemctl start nscd

# Or increase script performance
# Make sure script does minimal work
```

### Problem: Script not being called
```bash
# Check script permissions
ls -l /sbin/nss_exec

# Should be: -rwxr-xr-x root root

# Test script directly
sudo /sbin/nss_exec getpwnam testuser

# Check nsswitch.conf
cat /etc/nsswitch.conf | grep exec
```

## Debugging Tools

### Enable verbose logging in script
```bash
#!/bin/bash
# Add at top of /sbin/nss_exec
exec 2>> /tmp/nss_exec_debug.log
set -x  # Enable debug output

# Now watch logs
tail -f /tmp/nss_exec_debug.log
```

### Use strace to see NSS calls
```bash
strace -e trace=open,openat,read getent passwd testuser 2>&1 | grep nss
```

### Check library dependencies
```bash
ldd /usr/lib/libnss_exec.so.2
```

## Success Criteria

You're ready for production when:

1. ✅ All getent commands work
2. ✅ System users unaffected
3. ✅ No crashes under load
4. ✅ Performance < 100ms with caching
5. ✅ Security tests pass
6. ✅ Monitoring in place

## Next Steps

Once testing is complete:
1. Document your specific use case
2. Create monitoring/alerting
3. Set up backup authentication method
4. Deploy gradually (staging → production)
5. Monitor logs closely for first 24 hours

Good luck! 🚀
