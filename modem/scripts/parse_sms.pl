#!/usr/bin/perl
use strict;
use warnings;
use Fcntl qw(:flock);

# Serialize all AT operations on /dev/smd7 with /data/del_sms.sh
open(my $lock_fh, ">", "/tmp/.sms_at.lock") or die "Cannot open lock";
flock($lock_fh, LOCK_EX);

sub swap_nibbles {
    my ($hex) = @_;
    my $res = "";
    for (my $i = 0; $i < length($hex); $i += 2) {
        my $b = substr($hex, $i, 2);
        my $lo = substr($b, 1, 1);
        my $hi = substr($b, 0, 1);
        $res .= $lo . ($hi =~ /f/i ? "" : $hi);
    }
    return $res;
}

sub decode_7bit {
    my ($hex, $udl, $skip_septets) = @_;
    $skip_septets ||= 0;
    my $bin = "";
    for (my $i = 0; $i < length($hex); $i += 2) {
        $bin .= reverse(sprintf("%08b", hex(substr($hex, $i, 2))));
    }
    my $text = "";
    for (my $i = $skip_septets; $i < $udl; $i++) {
        last if ($i * 7 + 7 > length($bin));
        my $val = oct("0b" . reverse(substr($bin, $i * 7, 7)));
        $text .= chr($val);
    }
    return $text;
}

sub extract_code {
    my ($text) = @_;
    return "" unless $text;

    # 必须包含验证码相关关键词
    return "" unless ($text =~ /(?:验证码|校验码|动态码|确认码|随机码|授权码|激活码|安全码|动态密码|认证码|提取码|code)/i);

    my $s = $text;
    # 1. 过滤 URL
    $s =~ s{https?://\S+}{ }g;
    $s =~ s{[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z]{2,}(?:/[^\s\x{4e00}-\x{9fa5}]*)?}{ }g;

    # 2. 过滤日期时间与时效
    $s =~ s{\d{4}[-/年.]\d{1,2}[-/月.]\d{1,2}}{ }g;
    $s =~ s{\d{1,2}:\d{2}(?::\d{2})?}{ }g;
    $s =~ s{\d+\s*(?:分钟|分|秒|小时|天|min|mins|minute|minutes)}{ }gi;

    # 3. 过滤银行卡尾号、金额、短号电话
    $s =~ s{(?:尾号|末\s*[四4]\s*位)\s*\d{4}}{ }g;
    $s =~ s{\d+(?:\.\d+)?\s*(?:元|块|RMB|¥|\$)}{ }g;
    $s =~ s{(?:10086|10010|10000|12580|12306|95\d{3,4}|400[-0-9]+)}{ }g;

    # 4. 正向关键词优先 (4~8位纯数字)
    if ($s =~ /(?:验证码|校验码|动态码|确认码|随机码|授权码|激活码|安全码|动态密码|认证码|提取码|code)\s*[:：为是\s=\-_]*\s*([0-9]{4,8})(?![0-9])/i) {
        return $1;
    }

    # 5. 反向关键词
    if ($s =~ /(?<![0-9])([0-9]{4,8})\s*(?:[，,。！!]|为|是|作为|即为)?\s*(?:您|本次|登录|注册|修改|操作|验证)?\s*(?:的)?\s*(?:验证码|校验码|动态码|动态密码|确认码|安全码)/i) {
        return $1;
    }

    # 6. 特殊括号包裹
    if ($s =~ /[【\[\(（#*]\s*([0-9]{4,8})\s*[】\]\)）#*]/) {
        return $1;
    }

    # 7. 兜底匹配首个独立数字
    if ($s =~ /(?<![0-9])([0-9]{4,8})(?![0-9])/) {
        return $1;
    }

    return "";
}

sub parse_pdu {
    my ($pdu_hex) = @_;
    my $bytes = pack("H*", $pdu_hex);
    return undef if length($bytes) < 8;

    my $smsc_len = ord(substr($bytes, 0, 1));
    my $pos = 1 + $smsc_len;
    return undef if $pos >= length($bytes);

    my $first_octet = ord(substr($bytes, $pos, 1));
    my $has_udhi    = ($first_octet & 0x40) ? 1 : 0;
    $pos += 1;

    my $sender_digits_count = ord(substr($bytes, $pos, 1));
    my $sender_type         = ord(substr($bytes, $pos + 1, 1));
    $pos += 2;

    my $sender_bytes_len = int(($sender_digits_count + 1) / 2);
    return undef if $pos + $sender_bytes_len > length($bytes);

    my $sender_hex = unpack("H*", substr($bytes, $pos, $sender_bytes_len));
    $pos += $sender_bytes_len;
    my $sender_num = swap_nibbles($sender_hex);
    my $sender = ($sender_type == 0x91 ? "+" : "") . $sender_num;

    my $tp_pid = ord(substr($bytes, $pos, 1));
    my $tp_dcs = ord(substr($bytes, $pos + 1, 1));
    $pos += 2;

    return undef if $pos + 7 > length($bytes);
    my $ts_hex = unpack("H*", substr($bytes, $pos, 7));
    $pos += 7;
    my $ts_digits = swap_nibbles($ts_hex);
    my $date_str = sprintf("20%s-%s-%s %s:%s:%s",
        substr($ts_digits, 0, 2), substr($ts_digits, 2, 2), substr($ts_digits, 4, 2),
        substr($ts_digits, 6, 2), substr($ts_digits, 8, 2), substr($ts_digits, 10, 2));

    my $udl = ord(substr($bytes, 0, 1));
    $pos += 1;

    my $ud_bytes = substr($bytes, $pos);
    my $text_bytes = $ud_bytes;

    my $part_ref   = 0;
    my $part_total = 1;
    my $part_seq   = 1;

    if ($has_udhi && length($ud_bytes) > 0) {
        my $udhl = ord(substr($ud_bytes, 0, 1));
        if (length($ud_bytes) >= 1 + $udhl) {
            my $udh = substr($ud_bytes, 1, $udhl);
            $text_bytes = substr($ud_bytes, 1 + $udhl);

            my $ie_pos = 0;
            while ($ie_pos < length($udh)) {
                my $iei = ord(substr($udh, $ie_pos, 1));
                my $iel = ($ie_pos + 1 < length($udh)) ? ord(substr($udh, $ie_pos + 1, 1)) : 0;
                last if ($ie_pos + 2 + $iel > length($udh));
                my $ied = substr($udh, $ie_pos + 2, $iel);

                if ($iei == 0x00 && $iel == 3) {
                    $part_ref   = ord(substr($ied, 0, 1));
                    $part_total = ord(substr($ied, 1, 1));
                    $part_seq   = ord(substr($ied, 2, 1));
                } elsif ($iei == 0x08 && $iel == 4) {
                    $part_ref   = (ord(substr($ied, 0, 1)) << 8) | ord(substr($ied, 1, 1));
                    $part_total = ord(substr($ied, 2, 1));
                    $part_seq   = ord(substr($ied, 3, 1));
                }
                $ie_pos += 2 + $iel;
            }
        }
    }

    my $content = "";
    if ($tp_dcs == 0x08) { # UCS-2BE (UTF-16BE)
        for (my $i = 0; $i + 1 < length($text_bytes); $i += 2) {
            my $cp = (ord(substr($text_bytes, $i, 1)) << 8) | ord(substr($text_bytes, $i + 1, 1));
            if ($cp < 0x80) {
                $content .= chr($cp);
            } elsif ($cp < 0x800) {
                $content .= chr(0xC0 | ($cp >> 6)) . chr(0x80 | ($cp & 0x3F));
            } else {
                $content .= chr(0xE0 | ($cp >> 12)) . chr(0x80 | (($cp >> 6) & 0x3F)) . chr(0x80 | ($cp & 0x3F));
            }
        }
    } elsif (($tp_dcs & 0x0C) == 0 || $tp_dcs == 0x00) { # 7-bit GSM
        my $skip = 0;
        if ($has_udhi && length($ud_bytes) > 0) {
            my $udhl = ord(substr($ud_bytes, 0, 1));
            my $fill_bits = (7 - ((1 + $udhl) * 8 % 7)) % 7;
            $skip = int(((1 + $udhl) * 8 + $fill_bits) / 7);
        }
        my $ud_hex = unpack("H*", $ud_bytes);
        $content = decode_7bit($ud_hex, $udl, $skip);
    } else {
        $content = $text_bytes;
    }

    return {
        sender     => $sender,
        date       => $date_str,
        content    => $content,
        part_ref   => $part_ref,
        part_total => $part_total,
        part_seq   => $part_seq
    };
}

sub load_ims_json_items {
    my @items;
    my $ims_file = "/data/ims_inbox.json";
    my $del_sigs = "/data/.deleted_ims_sigs";
    return @items unless (-s $ims_file);

    my %del_map;
    if (open(my $dfh, "<", $del_sigs)) {
        while (my $l = <$dfh>) {
            $l =~ s/[\r\n]+$//;
            $del_map{$l} = 1 if $l ne "";
        }
        close($dfh);
    }

    my $jfield = sub {
        my ($obj, $key) = @_;
        if ($obj =~ /"\Q$key\E"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            my $v = $1;
            $v =~ s/\\n/\n/g; $v =~ s/\\r/\r/g; $v =~ s/\\t/\t/g;
            $v =~ s/\\"/"/g; $v =~ s/\\\\/\\/g;
            return $v;
        } elsif ($obj =~ /"\Q$key\E"\s*:\s*(\d+)/) {
            return $1;
        }
        return "";
    };

    if (open(my $lfh, ">", "/tmp/.ims_inbox.lock")) {
        flock($lfh, LOCK_EX);
        if (open(my $fh, "<", $ims_file)) {
            local $/;
            my $raw = <$fh>;
            close($fh);
            while ($raw =~ /(\{[^{}]*\})/g) {
                my $obj = $1;
                my $sig = $jfield->($obj, "date") . "_" . $jfield->($obj, "sender") . "_" . $jfield->($obj, "content");
                next if $del_map{$sig};
                push @items, $obj;
            }
        }
        flock($lfh, LOCK_UN);
        close($lfh);
    }
    return @items;
}

sub at {
    my ($c) = @_;
    my $o = `atcli '$c' 2>&1`;
    $o =~ s/\r//g if defined $o;
    return $o || "";
}

# 1. 快速检查存储槽位状态 (轻量级探测，保护串口)
my $cpms_stat = at("AT+CPMS?");
my $sm_count = 0;
my $me_count = 0;
if ($cpms_stat =~ /\+CPMS:\s*"SM",(\d+)/) { $sm_count = int($1); }
if ($cpms_stat =~ /\+CPMS:[^\n]*"ME",(\d+)/) { $me_count = int($1); }

if ($sm_count == 0 && $me_count == 0 && $cpms_stat =~ /OK/) {
    my @ims_items = load_ims_json_items();
    my $json = "{\"ok\":true,\"count\":" . scalar(@ims_items) . ",\"next_index\":0,\"messages\":[" . join(",", @ims_items) . "]}\n";
    print $json;
    if (open(my $fh, ">", "/data/inbox.json")) {
        print $fh $json;
        close($fh);
    }
    exit 0;
}

my @raw_msgs;
my $max_idx = -1;
my $total_raw = "";

# 优先只扫描有短信的存储区
my @storages;
push @storages, 'SM' if ($sm_count > 0 || $cpms_stat !~ /\+CPMS/);
push @storages, 'ME' if ($me_count > 0);
@storages = ('SM') unless @storages;

for my $st (@storages) {
    my $raw = "";
    $raw .= at("AT+CPMS=\"$st\",\"$st\",\"$st\"");
    $raw .= at("AT+CMGF=0");
    $raw .= at("AT+CMGL=4");
    $total_raw .= "[$st]\n" . $raw . "\n";

    my @lines = grep { /\S/ } split(/\n/, $raw);
    for (my $i = 0; $i < @lines; $i++) {
        if ($lines[$i] =~ /\+CMGL:\s*(\d+)/) {
            my $idx = int($1);
            my $pdu = "";
            for (my $j = $i + 1; $j < @lines && $j <= $i + 4; $j++) {
                my $cand = $lines[$j];
                $cand =~ s/\s+//g;
                if ($cand =~ /^[0-9A-Fa-f]{10,}$/) {
                    $pdu = $cand;
                    last;
                }
            }
            next unless $pdu;
            my $parsed = eval { parse_pdu($pdu) };
            next unless ($parsed && $parsed->{sender} && $parsed->{date});
            $max_idx = $idx if $idx > $max_idx;
            $parsed->{index}   = $idx;
            $parsed->{storage} = $st;
            push @raw_msgs, $parsed;
        }
    }
}

if (open(my $rfh, ">", "/tmp/last_at_raw.txt")) {
    print $rfh $total_raw;
    close($rfh);
}

# 2. 长短信 (Concatenated SMS) 智能重组缝合，并完整记录所有物理分片槽位 indices
my %concat_map;
my @final_msgs;

for my $m (@raw_msgs) {
    if ($m->{part_total} > 1 && $m->{part_ref} > 0) {
        my $k = "$m->{storage}_$m->{sender}_$m->{part_ref}_$m->{part_total}";
        $concat_map{$k} ||= {
            index      => $m->{index},
            indices    => [],
            storage    => $m->{storage},
            sender     => $m->{sender},
            date       => $m->{date},
            part_total => $m->{part_total},
            parts      => {}
        };
        $concat_map{$k}{parts}{$m->{part_seq}} = $m->{content};
        push @{$concat_map{$k}{indices}}, $m->{index};
        $concat_map{$k}{index} = $m->{index} if ($m->{index} < $concat_map{$k}{index});
    } else {
        $m->{indices} = "$m->{index}";
        push @final_msgs, $m;
    }
}

for my $k (sort keys %concat_map) {
    my $g = $concat_map{$k};
    my $full_text = "";
    for my $s (1 .. $g->{part_total}) {
        $full_text .= ($g->{parts}{$s} // "");
    }
    my @sorted_idx = sort { $a <=> $b } @{$g->{indices}};
    push @final_msgs, {
        index   => $g->{index},
        indices => join("-", @sorted_idx),
        storage => $g->{storage},
        sender  => $g->{sender},
        date    => $g->{date},
        content => $full_text
    };
}

# 排序并生成 JSON
@final_msgs = sort { $a->{index} <=> $b->{index} } @final_msgs;

my @json_items;
for my $m (@final_msgs) {
    my $c = $m->{content};
    my $code = extract_code($c);
    my $idxs = $m->{indices} || "$m->{index}";
    $c =~ s/\\/\\\\/g;
    $c =~ s/"/\\"/g;
    $c =~ s/\r/\\r/g;
    $c =~ s/\n/\\n/g;
    $c =~ s/\t/\\t/g;
    push @json_items, "{\"index\":$m->{index},\"indices\":\"$idxs\",\"storage\":\"$m->{storage}\",\"sender\":\"$m->{sender}\",\"date\":\"$m->{date}\",\"code\":\"$code\",\"content\":\"$c\"}";
}

my $next_idx = ($max_idx >= 0) ? ($max_idx + 1) : 0;
push @json_items, load_ims_json_items();
my $json = "{\"ok\":true,\"count\":" . scalar(@json_items) . ",\"next_index\":$next_idx,\"messages\":[" . join(",", @json_items) . "]}\n";
print $json;

if (open(my $fh, ">", "/data/inbox.json")) {
    print $fh $json;
    close($fh);
}
