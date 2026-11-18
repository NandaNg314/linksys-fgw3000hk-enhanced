#!/usr/bin/perl
use strict;
use warnings;
use Fcntl qw(:flock);

my $target = $ARGV[0] || "10086";
my $msg    = $ARGV[1] || "101";

print "[*] Target: $target, Msg: $msg\n";

open(my $lock_fh, ">", "/tmp/.sms_at.lock") or die "Cannot open lock: $!\n";
flock($lock_fh, LOCK_EX);

system("stty -F /dev/smd7 raw -echo -icrnl -onlcr min 0 time 10 2>/dev/null");

open(my $fh, "+<", "/dev/smd7") or die "Cannot open /dev/smd7: $!\n";

syswrite($fh, "\x1b\r");
sleep(1);
my $buf = "";
sysread($fh, $buf, 1024);

syswrite($fh, "ATE0\r");
sleep(1);
sysread($fh, $buf, 1024);

syswrite($fh, "AT+CMGF=1\r");
sleep(1);
sysread($fh, $buf, 1024);
print "[*] CMGF: $buf\n";

syswrite($fh, "AT+CGSMS=1\r");
sleep(1);
sysread($fh, $buf, 1024);

syswrite($fh, "AT+CMGS=\"$target\"\r");
sleep(2);
$buf = "";
sysread($fh, $buf, 1024);
print "[*] CMGS Prompt: [$buf]\n";

syswrite($fh, "$msg\x1a");
print "[*] Message body sent, waiting for network ACK...\n";

for my $i (1..8) {
    sleep(1);
    my $chunk = "";
    sysread($fh, $chunk, 1024);
    if ($chunk) {
        $buf .= $chunk;
        print "[*] Recv: $chunk\n";
        last if $chunk =~ /OK|\+CMGS:|ERROR/;
    }
}

close($fh);
flock($lock_fh, LOCK_UN);
close($lock_fh);
print "[*] Final Result: $buf\n";