package Class::Multimethods;

use strict;
use vars qw($VERSION @ISA @EXPORT);
use Carp;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw( multimethod resolve_ambiguous resolve_no_match );
$VERSION = '1.10';

my %dispatch = ();	     # THE DISPATCH TABLE
my %cached   = ();	     # THE CACHE OF PREVIOUS RESOLUTIONS OF EMPTY SLOTS
my %hasgeneric  = ();	     # WHETHER A GIVEN MULTIMETHOD HAS ANY GENERIC VARIANTS
my %ambiguous_handler = ();  # HANDLERS FOR AMBIGUOUS CALLS
my %no_match_handler = ();   # HANDLERS FOR AMBIGUOUS CALLS


# THIS IS INTERPOSED BETWEEN THE CALLING PACKAGE AND Exporter TO SUPPORT THE
# use Class:Multimethods @methodnames SYNTAX

sub import
{
	my $package = (caller)[0];
	install_dispatch($package,pop @_) while $#_;
	Class::Multimethods->export_to_level(1);
}


# INSTALL A DISPATCHING SUB FOR THE NAMED MULTIMETHOD IN THE CALLING PACKAGE

sub install_dispatch
{
	my ($pkg, $name) = @_;
	eval "sub ${pkg}::$name { Class::Multimethods::dispatch('$name',\@_) }"
		unless eval "defined \&${pkg}::$name";
}

# REGISTER RESOLUTION FUNCTIONS FOR AMBIGUOUS AND NO-MATCH CALLS

sub resolve_ambiguous
{
	my $name = shift;
	if (@_ == 1 && ref($_[0]) eq 'CODE')
		{ $ambiguous_handler{$name} = $_[0] }
	else
		{ $ambiguous_handler{$name} = join ',', @_ }
}

sub resolve_no_match
{
	my $name = shift;
	if (@_ == 1 && ref($_[0]) eq 'CODE')
		{ $no_match_handler{$name} = $_[0] }
	else
		{ $no_match_handler{$name} = join ',', @_ }
}

# SQUIRREL AWAY THE PROFFERED SUB REF INDEXED BY THE MULTIMETHOD NAME
# AND THE TYPE NAMES SUPPLIED. CAN ALSO BE USED WITH JUST THE MULTIMETHOD
# NAME IN ORDER TO INSTALL A SUITABLE DISPATCH SUB INTO THE CALLING PACKAGE

sub multimethod
{
	my $package = (caller)[0];
	my $name  = shift;
	install_dispatch($package,$name);

	if (@_)	  # NOT JUST INSTALLING A DISPATCH SUB...
	{
		my $code = pop;
		croak "multimethod: last arg must be a code reference"
			unless ref($code) eq 'CODE';

		my @types = @_;
		my $sig = join ',', @types;

		$hasgeneric{$name} ||= $sig =~ /\*/;

		$dispatch{$name}{$sig}{'&'} = $code;

		# NOTE: ADDING A MULTIMETHOD COMPROMISES CACHING
		# THIS IS A DUMB, BUT FAST, FIX...
		$cached{$name} = {};
	}
}


# THIS IS THE ACTUAL MEAT OF THE PACKAGE -- A GENERIC DISPATCHING SUB
# WHICH EXPLORES THE %dispatch AND %cache HASHES LOOKING FOR A UNIQUE
# BEST MATCH...

sub dispatch   # ($multimethod_name, @actual_args)
{
	my $name = shift;

# MAP THE ARGS TO TYPE NAMES, MAP VALUES TO '#' (FOR NUMBERS)
# OR '$' (OTHERWISE). THEN BUILD A FUNCTION TYPE SIGNATURE
# (LIKE A "PATH" INTO THE VARIOUS TABLES)

	my @types = do {local $^W; (map {ref || $_+0 eq $_ && '#' || '$' } @_)};
	my $sig = join ',', @types;

	my $code = $dispatch{$name}{$sig}{'&'} 
		|| $cached{$name}{$sig}{'&'};
	return $code->(@_) if $code;

	my %tried = ();	   # USED TO AVOID MULTIPLE MATCHES ON THE SAME SIG
	my @code;          # WILL STORE LIST OF EQUALLY CLOSELY MATCHING SUBS
	my @candidates = ( [@types] );	# STORES POSSIBLE MATCHING SIGNATURES

# TRY AND RESOLVE TO AN TYPE-EXPLICIT SIGNATURE (USING INHERITANCE)

	1 until (resolve($name,\@candidates,\@code,\%tried) || !@candidates);

# IF THAT DOESN'T WORK, TRY A GENERIC SIGNATURE (IF THERE ARE ANY)
# THE NESTED LOOPS GENERATE ALL POSSIBLE PERMUTATIONS OF GENERIC SIGNATURES
# IN SUCH A WAY THAT, EACH TIME resolve IS CALLED, ALL THE CANDIDATES ARE 
# EQUALLY GENERIC (HAVE AN EQUAL NUMBER OF GENERIC PLACEHOLDERS)

	if ( @code == 0 && $hasgeneric{$name} )	# TRY GENERIC VERSIONS
	{
		my @gencandidates = ([@types]);
		GENERIC: for (0..$#types)
		{
			@candidates = ();
			for (my $gci=0; $gci<@gencandidates; $gci++)
			{
				for (my $i=0; $i<@types; $i++)
				{
					push @candidates, [@{$gencandidates[$gci]}];
					$candidates[-1][$i] = "*";
				}
			}
			@gencandidates = @candidates;
			1 until (resolve($name,\@candidates,\@code,\%tried) || !@candidates);
			last GENERIC if @code;
		}
	}

# RESOLUTION PROCESS COMPLETED...
# IF EXACTLY ONE BEST MATCH, CALL IT...

	if ( @code == 1 )
	{
		$cached{$name}{$sig}{'&'} = $code[0];
		# print "caching {$name}{$sig}{'&'}\n";
		return $code[0]->(@_);
	}

# TWO OR MORE EQUALLY LIKELY CANDIDATES IS AMBIGUOUS...
	elsif ( @code > 1)
	{
		my $handler = $ambiguous_handler{$name};
		if (defined $handler)
		{
			return $handler->(@_)
				if ref $handler;
			return $dispatch{$name}{$handler}{'&'}->(@_)
				if defined $dispatch{$name}{$handler};
		}
		croak "Cannot resolve call to multimethod $name($sig). " .
		      "The multimethods:\n" .
			join("\n",
			 map { "\t$name(" . join(',',@$_) . ")" } @candidates) .
			"\nare equally viable";
	}

# IF *NO* CANDIDATE, NO WAY TO DISPATCH THE CALL
	else
	{
		my $handler = $no_match_handler{$name};
		if (defined $handler)
		{
			return $handler->(@_)
				if ref $handler;
			return $dispatch{$name}{$handler}{'&'}->(@_)
				if defined $dispatch{$name}{$handler};
		}
		croak "No viable candidate for call to multimethod $name($sig)";
	}
}


# THIS SUB TAKES A LIST OF EQUALLY LIKELY CANDIDATES (I.E. THE SAME NUMBER OF
# INHERITANCE STEPS AWAY FROM THE ACTUAL ARG TYPES) AND BUILDS A LIST OF
# MATCHING ONES. IF THERE AREN'T ANY MATCHES, IT BUILDS A NEW LIST OF
# CANDIDATES, BY GENERATING PERMUTATIONS OF THE SET OF PARENT TYPES FOR
# EACH ARG TYPE.

sub resolve
{
	my ($name, $candidates, $matches, $tried) = @_;
	my %newcandidates = ();
	foreach my $candidate ( @$candidates )
	{
	# BUILD THE TYPE SIGNATURE AND ENSURE IT HASN'T ALREADY BEEN CHECKED

     	 	my $sig = join ',', @$candidate;
		next if $tried->{$sig};
		$tried->{$sig} = 1;
	
	# LOOK FOR A MATCHING SUB REF IN THE DISPATCH TABLE AND REMEMBER IT...

		my $match = $dispatch{$name}{$sig}{'&'};
		if ($match && ref($match) eq 'CODE') 
		{
			push @$matches, $match;
		}

	# OTHERWISE, GENERATE A NEW SET OF CANDIDATES BY REPLACING EACH
	# ARGUMENT TYPE IN TURN BY EACH OF ITS IMMEDIATE PARENTS. EACH SUCH
	# NEW CANDIDATE MUST BE EXACTLY 1 DERIVATION MORE EXPENSIVE THAN
	# THE CURRENT GENERATION OF CANDIDATES. NOTE, THAT IF A MATCH HAS
	# BEEN FOUND AT THE CURRENT GENERATION, THERE IS NO NEED TO LOOK
	# ANY DEEPER...

		elsif (!@$matches)
		{
			for (my $i = 0; $i<@$candidate ; $i++)
			{
				next if $candidate->[$i] =~ /[^\w:#]/;
				no strict 'refs';
				my @parents = ($candidate->[$i] eq '#') ? ('$')
						: @{$candidate->[$i]."::ISA"};
				foreach my $parent ( @parents )
				{
					my @newcandidate = @$candidate;
					$newcandidate[$i] = $parent;
					$newcandidates{join ',', @newcandidate} = [@newcandidate];
				}
			}
			
		}
	}

# IF NO MATCHES AT THE CURRENT LEVEL, RESET THE CANDIDATES TO THOSE AT
# THE NEXT LEVEL...

	@$candidates = values %newcandidates unless @$matches;

	return scalar @$matches;
}


1;
__END__
