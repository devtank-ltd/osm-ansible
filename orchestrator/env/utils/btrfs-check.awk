#!/usr/bin/gawk -f

# Send BTRFS scrub, device and filesystem usage statistics to recipients if there are problems

BEGIN {
    MOUNT_POINT = "/srv/incus"
    THRESHOLD = 50              # at least 50 gigabytes must be free
    RECIPIENTS = "<recipient>@<mail host>"
    SUBJ = "BTRFS health report: problems detected"
    HAS_PROBLEMS = 0
    BODY = ""

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
