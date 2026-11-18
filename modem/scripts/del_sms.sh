#!/bin/sh
TARGET="$1"
ARG2="$2"

perl - "$TARGET" "$ARG2" << 'PERL_EOF'
use strict;
use warnings;
use Fcntl qw(:flock);

my $target = $ARGV[0] // "";
my $arg2   = $ARGV[1] // "";

for ($target, $arg2) {
    s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
    s/^\s+|\s+$//g;
}

my $ims_file = "/data/ims_inbox.json";
my $del_sigs = "/data/.deleted_ims_sigs";

sub json_field {
    my ($obj, $key) = @_;
    if ($obj =~ /"\Q$key\E"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
        my $v = $1;
        $v =~ s/\\n/\n/g;
        $v =~ s/\\r/\r/g;
        $v =~ s/\\t/\t/g;
        $v =~ s/\\"/"/g;
        $v =~ s/\\\\/\\/g;
        return $v;
    } elsif ($obj =~ /"\Q$key\E"\s*:\s*(\d+)/) {
        return $1;
    }
    return "";
}

sub record_del_sig {
    my ($obj) = @_;
    my $d = json_field($obj, "date");
    my $s = json_field($obj, "sender");
    my $c = json_field($obj, "content");
    return unless ($d && $s);
    if (open(my $dfh, ">>", $del_sigs)) {
        print $dfh "${d}_${s}_${c}\n";
        close($dfh);
    }
    if (open(my $rfh, "<", $del_sigs)) {
        my @lines = <$rfh>;
        close($rfh);
        if (@lines > 200) {
            @lines = @lines[-150 .. -1];
            if (open(my $wfh, ">", "$del_sigs.tmp")) {
                print $wfh @lines;
                close($wfh);
                rename("$del_sigs.tmp", $del_sigs);
            }
        }
    }
}

sub delete_ims_ids {
    my (@ids) = @_;
    my %del = map { int($_) => 1 } grep { /^\d+$/ } @ids;
    return unless (-s $ims_file);
    if (open(my $lfh, ">", "/tmp/.ims_inbox.lock")) {
        flock($lfh, LOCK_EX);
        if (open(my $fh, "<", $ims_file)) {
            local $/;
            my $raw = <$fh>;
            close($fh);
            my @kept;
            while ($raw =~ /(\{[^{}]*\})/g) {
                my $obj = $1;
                my $idx = json_field($obj, "index");
                if ($idx ne "" && (%del ? $del{int($idx)} : 1)) {
                    record_del_sig($obj);
                } else {
                    push @kept, $obj;
                }
            }
            if (@kept) {
                if (open(my $wfh, ">", "$ims_file.tmp")) {
                    print $wfh "[" . join(",", @kept) . "]";
                    close($wfh);
                    rename("$ims_file.tmp", $ims_file);
                }
            } else {
                unlink($ims_file);
            }
        }
        flock($lfh, LOCK_UN);
        close($lfh);
    }
}

sub at {
    my ($c) = @_;
    my $o = `atcli '$c' 2>&1`;
    return $o // "";
}

my $need_at = 1;
if ($target eq "all") {
    delete_ims_ids();
} elsif (uc($arg2) eq "IMS") {
    my @ids = split(/[-,]/, $target);
    delete_ims_ids(@ids);
    $need_at = 0;
} elsif ($target eq "batch") {
    my @ims_ids;
    my @at_items;
    for my $item (split(/,/, $arg2)) {
        if ($item =~ /^([0-9,\-]+):IMS$/i) {
            push @ims_ids, split(/[-,]/, $1);
        } elsif ($item =~ /\S/) {
            push @at_items, $item;
        }
    }
    delete_ims_ids(@ims_ids) if @ims_ids;
    if (!@at_items) {
        $need_at = 0;
    } else {
        $arg2 = join(",", @at_items);
    }
}

if ($need_at && open(my $lock_fh, ">", "/tmp/.sms_at.lock")) {
    flock($lock_fh, LOCK_EX);

    if ($target eq "all") {
        for my $st ("SM", "ME") {
            at("AT+CPMS=\"$st\",\"$st\",\"$st\"");
            my $res = at("AT+CMGD=1,4");
            if ($res =~ /ERROR/i) {
                my $cmgl = at("AT+CMGF=0") . "\n" . at("AT+CMGL=4");
                while ($cmgl =~ /\+CMGL:\s*(\d+)/g) {
                    at("AT+CMGD=$1");
                }
            }
        }
    } else {
        my %by_st;
        my @items;
        if ($target eq "batch") {
            @items = split(/,/, $arg2);
        } else {
            my $st = ($arg2 =~ /^(SM|ME)$/i) ? uc($arg2) : "SM";
            if ($target =~ /^([0-9,\-]+):(SM|ME)$/i) {
                push @items, "$1:" . uc($2);
            } else {
                push @items, "$target:$st";
            }
        }

        for my $item (@items) {
            next unless defined $item && $item =~ /\S/;
            my ($idx_part, $st) = split(/:/, $item, 2);
            $st = ($st && $st =~ /^(SM|ME)$/i) ? uc($st) : "SM";
            for my $n (split(/[-,]/, $idx_part // "")) {
                if ($n =~ /^\d+$/) {
                    $by_st{$st}{int($n)} = 1;
                }
            }
        }

        for my $st (sort keys %by_st) {
            at("AT+CPMS=\"$st\",\"$st\",\"$st\"");
            for my $idx (sort { $a <=> $b } keys %{$by_st{$st}}) {
                at("AT+CMGD=$idx");
            }
        }
    }

    flock($lock_fh, LOCK_UN);
    close($lock_fh);
}
PERL_EOF

exec perl /data/parse_sms.pl