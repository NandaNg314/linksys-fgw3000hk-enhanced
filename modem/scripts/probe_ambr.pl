#!/usr/bin/perl
use strict;
use warnings;
use Fcntl qw(:flock);

my $force = (@ARGV && $ARGV[0] eq "--force") ? 1 : 0;

open(my $plock, ">", "/tmp/.ambr_probe.lock") or exit 0;
flock($plock, LOCK_EX | LOCK_NB) or exit 0;

my $imsi = "";
if (!$force && open(my $ifh, "<", "/tmp/.cached_imsi")) {
    my $c = <$ifh> // "";
    close($ifh);
    $imsi = $1 if $c =~ /(\d{14,15})/;
}

my $base_apn = "cmnet";
if (open(my $alfh, ">", "/tmp/.sms_at.lock")) {
    flock($alfh, LOCK_EX);
    if (!$imsi) {
        my $cimi = `atcli 'AT+CIMI' 2>/dev/null`;
        if ($cimi && $cimi =~ /(\d{14,15})/) {
            $imsi = $1;
            if (open(my $wfh, ">", "/tmp/.cached_imsi")) { print $wfh "$imsi\n"; close($wfh); }
        }
    }
    my $cgd = `atcli 'AT+CGDCONT?' 2>/dev/null`;
    if ($cgd && $cgd =~ /\+CGDCONT:\s*1,"[^"]*","([^"]+)"/) {
        my $a = $1;
        $a =~ s/\..*$//;
        $base_apn = $a if $a ne "";
    }
    flock($alfh, LOCK_UN);
    close($alfh);
}

exit 1 unless $imsi =~ /^\d{14,15}$/;

my $cache_path = "/data/.cached_ambr.json";
if (!$force && open(my $cf, "<", $cache_path)) {
    local $/;
    my $old = <$cf> // "";
    close($cf);
    if ($old =~ /"ambr_available"\s*:\s*true/ &&
        $old =~ /"imsi"\s*:\s*"\Q$imsi\E"/) {
        exit 0;
    }
}

sub crc16_diag {
    my ($data) = @_;
    my $crc = 0xFFFF;
    for my $b (unpack("C*", $data)) {
        $crc ^= $b;
        for (1..8) {
            if ($crc & 1) { $crc = ($crc >> 1) ^ 0x8408; }
            else          { $crc >>= 1; }
        }
    }
    return $crc ^ 0xFFFF;
}

sub hdlc_frame {
    my ($raw) = @_;
    my $pkt = $raw . pack("v", crc16_diag($raw));
    my $esc = "";
    for my $b (unpack("C*", $pkt)) {
        if ($b == 0x7E)    { $esc .= "\x7D\x5E"; }
        elsif ($b == 0x7D) { $esc .= "\x7D\x5D"; }
        else               { $esc .= chr($b); }
    }
    return $esc . "\x7E";
}

sub hdlc_unescape {
    my ($s) = @_;
    $s =~ s/\x7D\x5E/\x7E/g;
    $s =~ s/\x7D\x5D/\x7D/g;
    return $s;
}

my $mcc  = substr($imsi, 0, 3);
my $mnc2 = substr($imsi, 3, 2);
my $mnc3 = sprintf("%03d", int($mnc2));
my $fqdn_apn = "${base_apn}.mnc${mnc3}.mcc${mcc}.gprs";
my @try_apns = ($fqdn_apn);
push @try_apns, "cmwap" if ($mcc eq "460" && ($mnc2 eq "00" || $mnc2 eq "02" || $mnc2 eq "04" || $mnc2 eq "07" || $mnc2 eq "08"));

my $cap_dir = "/tmp/.diag_ambr_cap";
my $cfg_f   = "/tmp/.ambr_5gsm.cfg";
system("rm -rf $cap_dir && mkdir -p $cap_dir");

open(my $cfg, ">:raw", $cfg_f) or exit 1;
print $cfg hdlc_frame("\x60\x00");
print $cfg hdlc_frame(pack("C x3 V", 0x73, 0));
for my $nitems (0x0FFF, 0x0BFF, 0x09FF, 0x08FF, 0x083F) {
    my $mbytes = ($nitems + 1) / 8;
    my @m = (0) x $mbytes;
    for my $bi (256..261) { $m[$bi] = 0xFF if $bi < $mbytes; }
    print $cfg hdlc_frame(pack("C x3 V V V", 0x73, 3, 11, $nitems) . pack("C*", @m));
}
close($cfg);

my $dpid = fork();
if ($dpid == 0) {
    open(STDOUT, ">", "/dev/null");
    open(STDERR, ">", "/dev/null");
    exec("diag_mdlog", "-f", $cfg_f, "-o", $cap_dir, "-s", "4", "-c");
    exit 1;
}
select(undef, undef, undef, 1.3);

if (open(my $lfh, ">", "/tmp/.sms_at.lock")) {
    flock($lfh, LOCK_EX);
    for my $tapn (@try_apns) {
        `atcli 'AT+CGDCONT=4,"IPV4V6","$tapn"' 2>/dev/null`;
        my $act = `atcli 'AT+CGACT=1,4' 2>/dev/null`;
        if ($act && $act =~ /\bOK\b/) {
            select(undef, undef, undef, 0.35);
            `atcli 'AT+CGACT=0,4' 2>/dev/null`;
            `atcli 'AT+CGDCONT=4' 2>/dev/null`;
            last;
        }
        `atcli 'AT+CGDCONT=4' 2>/dev/null`;
    }
    flock($lfh, LOCK_UN);
    close($lfh);
}

select(undef, undef, undef, 0.8);
system("diag_mdlog -k >/dev/null 2>&1; kill $dpid 2>/dev/null");
waitpid($dpid, 0);

# 3GPP TS 24.501 Table 9.11.4.14.1 Session-AMBR units in kbps
my %unit_kbps = (
    0x01 => 1,         0x02 => 4,         0x03 => 16,        0x04 => 64,
    0x05 => 256,       0x06 => 1000,      0x07 => 4000,      0x08 => 16000,
    0x09 => 64000,     0x0A => 256000,    0x0B => 1000000,   0x0C => 4000000,
    0x0D => 16000000,  0x0E => 64000000,  0x0F => 256000000,
);

my ($found_dl, $found_ul, $found_hex, $found_5qi, $found_arp, $found_dnn) = (undef, undef, undef, undef, undef, $base_apn);

if (opendir(my $dh, $cap_dir)) {
    my @qfiles = grep { /\.qmdl/ && -f "$cap_dir/$_" } readdir($dh);
    closedir($dh);
    OUTER: for my $fn (@qfiles) {
        open(my $fh, "<:raw", "$cap_dir/$fn") or next;
        local $/;
        my $raw = <$fh>;
        close($fh);
        for my $ch (split(/\x7E/, $raw), $raw) {
            my $u = hdlc_unescape($ch);
            while ($u =~ /\x2E([\x01-\x0F])(.)\xC2(.)(..)/sg) {
                my ($psi, $pti, $ssc_pdu, $qlen_raw) = (ord($1), ord($2), ord($3), $4);
                my $qlen = unpack("n", $qlen_raw);
                my $p = pos($u);
                next unless $qlen >= 4 && $qlen < 512 && $p + $qlen + 7 <= length($u);
                my $alen = ord(substr($u, $p + $qlen, 1));
                next unless $alen == 6;
                my $ab = substr($u, $p + $qlen + 1, 6);
                my ($udl, $dl_v, $uul, $ul_v) = unpack("C n C n", $ab);
                next unless exists($unit_kbps{$udl}) && exists($unit_kbps{$uul});

                # Optional IEs parse (0x79 QoS flow descriptions, 0x25 DNN) BEFORE accepting
                my $opt = substr($u, $p + $qlen + 7, 512);
                my $pkt_dnn = undef;
                if ($opt =~ /\x25([\x02-\x20])/s) {
                    my $dlen = ord($1);
                    my $dp = pos($opt);
                    if ($dp + $dlen <= length($opt)) {
                        my $ll = ord(substr($opt, $dp, 1));
                        if ($ll >= 1 && $ll < $dlen) {
                            my $str = substr($opt, $dp + 1, $ll);
                            $pkt_dnn = $str if $str =~ /^[A-Za-z0-9_\-]+$/;
                        }
                    }
                }
                # Strictly exclude ims/sos and require target primary data DNN
                next if defined($pkt_dnn) && (lc($pkt_dnn) eq "ims" || lc($pkt_dnn) eq "sos");
                next unless defined($pkt_dnn) && (lc($pkt_dnn) eq lc($base_apn) || ($base_apn eq "cmnet" && lc($pkt_dnn) eq "cmwap"));

                my ($pkt_5qi, $pkt_arp) = (undef, undef);
                if ($opt =~ /\x79(..)/s) {
                    my $flen = unpack("n", $1);
                    my $fp = pos($opt);
                    if ($flen >= 6 && $fp + $flen <= length($opt)) {
                        my $fbody = substr($opt, $fp, $flen);
                        my $idx = 3;
                        while ($idx + 2 <= length($fbody)) {
                            my ($pid_b, $plen_b) = unpack("C C", substr($fbody, $idx, 2));
                            $idx += 2;
                            last if $idx + $plen_b > length($fbody);
                            my $pval = substr($fbody, $idx, $plen_b);
                            if ($pid_b == 0x01 && $plen_b == 1) {
                                $pkt_5qi = ord($pval);
                            } elsif ($pid_b == 0x07 && $plen_b == 1) {
                                $pkt_arp = (ord($pval) >> 4) & 0x0F;
                            }
                            $idx += $plen_b;
                        }
                    }
                }

                $found_dl  = $unit_kbps{$udl} * $dl_v;
                $found_ul  = $unit_kbps{$uul} * $ul_v;
                $found_hex = "06" . unpack("H*", $ab);
                $found_5qi = $pkt_5qi;
                $found_arp = $pkt_arp;
                $found_dnn = $pkt_dnn;
                last OUTER;
            }
        }
    }
}

system("rm -rf $cap_dir $cfg_f");

if (defined($found_dl) && defined($found_ul) && $found_dl > 0) {
    my $dl_mbps = int(($found_dl + 500) / 1000);
    my $ul_mbps = int(($found_ul + 500) / 1000);
    my $q5  = defined($found_5qi) ? $found_5qi : "null";
    my $arp = defined($found_arp) ? $found_arp : "null";
    my $now = time();
    my $json = sprintf(
        qq({"ok":true,"imsi":"%s","ts":%d,"dnn":"%s","ambr_available":true,"ambr_dl_kbps":%d,"ambr_ul_kbps":%d,"ambr_dl_mbps":%d,"ambr_ul_mbps":%d,"ambr_raw_hex":"%s","ambr_source":"5gsm_ota_0xc2","ota_5qi":%s,"ota_arp":%s}\n),
        $imsi, $now, $found_dnn, $found_dl, $found_ul, $dl_mbps, $ul_mbps, $found_hex, $q5, $arp
    );
    my $tmp = "$cache_path.tmp.$$";
    if (open(my $wf, ">", $tmp)) {
        print $wf $json;
        close($wf);
        chmod(0644, $tmp);
        rename($tmp, $cache_path);
    }
    unlink("/tmp/.cell_qos.cache");
    print $json;
    exit 0;
}

exit 1;
