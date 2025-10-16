#!/usr/bin/gawk -f

# Send BTRFS scrub, device and filesystem usage statistics to recipients if there are problems

function err(msg, print_help) {
    print("!!! ERROR: " msg)
    if (print_help) {
        usage()
    }
    exit 1
}

function usage() {
    print
    print "Example usage:"
    print "./btrfs-check.awk -v MOUNT_POINT='</mount/point>' -v THRESHOLD=<num> -v RECIPIENTS='<name@domain>,[name@domain],...'"
    print
}

BEGIN {
    SUBJ = "BTRFS health report: problems detected"
    HAS_PROBLEMS = 0
    BODY = ""

    if (!MOUNT_POINT) {
        err("mount point must be set", 1)
    }

    if (!THRESHOLD) {
        err("threshould must be set", 1)
    }

    if (!RECIPIENTS) {
        err("email recipients must be set", 1)
    }


    # check unallocated space
    cmd = "btrfs filesystem usage --gbytes \"" MOUNT_POINT "\""
    while((cmd | getline line) > 0) {
        if (line ~ /Device unallocated:/) {
            match(line, /[[:digit:]]+\.[[:digit:]]+/, unalloc)
            if (unalloc[0]) {
                if (unalloc[0] <= THRESHOLD) {
                    body = body sprintf("WARNING: Free space: %.2fGB is less then needed (%.2fGB)\n", unalloc[0],THRESHOLD)
                    HAS_PROBLEMS = 1
                }
            } else {
                print "ERROR: unable to get unallocated space!"
                exit(1)
            }
        }

        if (line ~ /^Metadata/ && HAS_PROBLEMS) {
            body =  body sprintf("%s\n", line)
        }
    }
    close(cmd)

    # check scrub stats
    cmd = "btrfs scrub status \"" MOUNT_POINT "\""
    scrub_stats = ""
    while ((cmd | getline line) > 0) {

        if (line ~ /^Scrub started:/) {
            scrub_stats = scrub_stats sprintf("%s\n", line)
        }

        if (line ~ /^Duration:/) {
            scrub_stats = scrub_stats sprintf("%s\n", line)
        }

        if (line ~ /Error summary:/ && line !~ /no errors found/) {
            body = body scrub_stats sprintf("%s\n", line)
            HAS_PROBLEMS = 1
        }
    }
    close(cmd)

    # check device stats
    cmd = "btrfs device stats \"" MOUNT_POINT "\""
    while ((cmd | getline line) > 0) {

        if (match(line, /^\[([^\]]+)\]\.([a-z_]+)[[:space:]]+([0-9]+)/, m)) {
            dev = m[1]
            err_type = m[2]
            count = m[3] + 0

            if (count > 0) {
                HAS_PROBLEMS = 1
                body = body sprintf("Device error on %s: %s = %d\n", dev, err_type, count)
            }
        }
    }
    close(cmd)

    if (HAS_PROBLEMS) {
        cmd = "echo \"" body "\" | mail -s \"" SUBJ "\" \"" RECIPIENTS "\""
        system(cmd)
    }
    exit(0)
}
