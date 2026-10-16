#!/usr/bin/env perl
# Shared redaction (design §8), used by scrub.sh (artifact) and run-scenario.sh
# (public step-log replay), so both apply exactly the same rules.
#   redact.pl < in > out      filter; prints "redact: N" on stderr when N > 0
#   redact.pl -i FILE...      in place (rewritten only when a hit); prints the total hit count
#   redact.pl --pk FILE|-     exit 0 if private key material is present, 1 if not, 2 on error
# Key/value forms, case-insensitive: the key, an optional \ and quote (escaped
# JSON), ':' or '=', then a value: \"..\", "..", '..' or a bare token. Only the
# value becomes <redacted>. A key with an empty value, '|' or '>' at end of line
# is a hit too, and the more-indented lines after it are redacted (YAML block).
# An empty quoted value ("", '', \"\") followed by a boundary (space, ',', '}',
# ']', end of line; also '"' after \"\") is left alone and not counted: juju
# logs `request authToken: ""` on every password login (zero-hit baseline,
# design §8). `password: ""secret` is still a hit (the whole ""secret goes).
# Lower-case `token` (k8s credentials/kubeconfig) only matches with ':', since
# `token=` is common test data in shell traces (juju-qa-dummy-source hooks);
# upper-case env vars (`GITHUB_TOKEN=`, `JUJU_TOKEN=`), `--token=`/`--token x`
# and `access_token=` match with '='. Key-independent value shapes: JWTs
# (eyJ...eyJ...sig, e.g. a service-account Bearer token) and GitHub tokens
# (gh[pousr]_...) are redacted wherever they appear.
use strict;
use warnings;

my $KEY = qr/(?:password|apipassword|statepassword|oldpassword|admin-secret|macaroons?(?:-[\w-]+)?|client[-_]?key[-_]?data|access[-_]?token)/i;
my $SEP = qr/\\?["']?[ \t]*[:=][ \t]*/;
my $KS = qr/(?:${KEY}${SEP}|token\\?["']?[ \t]*:[ \t]*|(?-i:(?<![a-z])[A-Z0-9_]*TOKEN)=|--token(?:=|[ \t]+))/i;
my $EMPTY = qr/^(?:""|''|\\"\\")$/;
my $VAL = qr/(?:""|'')(?![\s,}\]]|$)\S+|\\"\\"(?![\s,}\]"]|$)\S+|\\"(?:(?!\\").)*\\"|"(?:[^"\\\n]|\\.)*"|'[^'\n]*'|[^\s]+/;
my $SHAPE = qr/eyJ[\w-]{8,}\.eyJ[\w-]{8,}\.[\w-]+|gh[pousr]_[A-Za-z0-9]{30,}/;
my $OPEN = qr/${KS}(?:[|>][-+0-9]*)?[ \t]*\r?$/;
# Clear-text PEM, or base64 of "-----BEGIN" that is not a certificate or public key.
my $PK = qr/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----|LS0tLS1CRUdJTi(?!BDRVJUSUZJQ0FURS0tLS0t|BQVUJMSUMgS0VZLS0tLS0)/;

# redact_stream(in_fh, out_fh) -> hits
sub redact_stream {
	my ($in, $out) = @_;
	my $hits = 0;
	my $block;    # indent width of an open YAML block key, or undef
	while (my $line = <$in>) {
		if (defined $block) {
			my ($ind) = $line =~ /^([ \t]*)/;
			if ($line =~ /^[ \t]*\r?\n?$/) { print $out $line; next; }
			if (length($ind) > $block) {
				my $nl = $line =~ /\n\z/ ? "\n" : "";
				print $out "$ind<redacted>$nl";
				next;
			}
			undef $block;
		}
		if ($line =~ $OPEN) {
			$hits++;
			($block) = map { length } $line =~ /^([ \t]*)/;
			print $out $line;
			next;
		}
		$line =~ s/(${KS})($VAL)/my ($k, $v) = ($1, $2); $v =~ $EMPTY ? "$k$v" : (++$hits, "$k<redacted>")[1]/ge;
		$hits += ($line =~ s/$SHAPE/<redacted>/g);
		print $out $line;
	}
	return $hits;
}

binmode STDIN;
binmode STDOUT;
if (@ARGV && $ARGV[0] eq '--pk') {
	shift @ARGV;
	for my $f (@ARGV ? @ARGV : ('-')) {
		my $fh;
		if ($f eq '-') { $fh = \*STDIN } else { open($fh, '<:raw', $f) or exit 2 }
		while (my $l = <$fh>) { exit 0 if $l =~ $PK }
	}
	exit 1;
}
if (@ARGV && $ARGV[0] eq '-i') {
	shift @ARGV;
	my $total = 0;
	for my $f (@ARGV) {
		open(my $in, '<:raw', $f) or die "redact: cannot read $f: $!\n";
		my $tmpf = "$f.redact.$$";
		open(my $out, '>:raw', $tmpf) or die "redact: cannot write $tmpf: $!\n";
		my $n = redact_stream($in, $out);
		close $in;
		close $out or die "redact: close $tmpf: $!\n";
		if ($n) { rename($tmpf, $f) or die "redact: rename $f: $!\n" } else { unlink $tmpf }
		$total += $n;
	}
	print "$total\n";
	exit 0;
}
my $n = redact_stream(\*STDIN, \*STDOUT);
print STDERR "redact: $n value(s) redacted\n" if $n;
exit 0;
