package Class::Multimethods;

use strict;
use vars qw($VERSION @ISA @EXPORT);
use Carp;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw( multimethod resolve_ambiguous resolve_no_match superclass
	      multimethod_wrapper );
$VERSION = '1.70';

use vars qw(%dispatch %cached %hasgeneric
	    %ambiguous_handler %no_match_handler
	    %max_args %min_args);

%dispatch = ();	          # THE DISPATCH TABLE
%cached   = ();	          # THE CACHE OF PREVIOUS RESOLUTIONS OF EMPTY SLOTS
%hasgeneric  = ();	  # WHETHER A GIVEN MULTIMETHOD HAS ANY GENERIC VARIANTS
%ambiguous_handler = ();  # HANDLERS FOR AMBIGUOUS CALLS
%no_match_handler = ();   # HANDLERS FOR AMBIGUOUS CALLS
%max_args = ();   	  # RECORDS MAX NUM OF ARGS IN ANY VARIANT
%min_args = ();		  # RECORDS MIN NUM OF ARGS IN ANY VARIANT


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
	# eval "sub ${pkg}::$name { Class::Multimethods::dispatch('$name',\@_) }"
	eval(make_dispatch($pkg,$name)) || croak "internal error: $@"
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

# GENERATE A SPECIAL PROXY OBJECT TO INDICATE THAT THE ANCESTOR OF AN OBJECT'S
# CLASS IS REQUIRED

sub superclass
{
	my ($obj, $super) = @_;
	$super = ref($obj) || ( (~$obj&$obj) eq 0 ? '#' : '$' ) if @_ <= 1;
	bless \$obj, (@_ > 1 )
		? "Class::Multimethods::SUPERCLASS_IS::$super"
		: "Class::Multimethods::SUPERCLASS_OF::$super";
}

sub _prettify
{
	   $_[0] =~ s/Class::Multimethods::SUPERCLASS_IS:://
	or $_[0] =~ s/Class::Multimethods::SUPERCLASS_OF::(.*)/superclass($1)/;
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

		for ($Class::Multimethods::max_args{$name})
			{ $_ = @types if !defined || @types > $_ }
		for ($Class::Multimethods::min_args{$name})
			{ $_ = @types if !defined || @types < $_ }
			
		my $sig = join ',', @types;

		$Class::Multimethods::hasgeneric{$name} ||= $sig =~ /\*/;

		carp "Multimethod $name($sig) redefined"
			if $^W && exists $dispatch{$name}{$sig};
		$dispatch{$name}{$sig} = $code;

		# NOTE: ADDING A MULTIMETHOD COMPROMISES CACHING
		# THIS IS A DUMB, BUT FAST, FIX...
		$cached{$name} = {};
	}
}


# THIS IS THE ACTUAL MEAT OF THE PACKAGE -- A GENERIC DISPATCHING SUB
# WHICH EXPLORES THE %dispatch AND %cache HASHES LOOKING FOR A UNIQUE
# BEST MATCH...

sub make_dispatch # ($name)
{
	my ($pkg,$name) = @_;
	my $code = q{

	sub PACKAGE::NAME
	{
	# MAP THE ARGS TO TYPE NAMES, MAP VALUES TO '#' (FOR NUMBERS)
	# OR '$' (OTHERWISE). THEN BUILD A FUNCTION TYPE SIGNATURE
	# (LIKE A "PATH" INTO THE VARIOUS TABLES)

		my $sig = "";
		my $nexttype;
		foreach ( @_ )
		{
			$nexttype = ref || ( (~$_&$_) eq 0 ? '#' : '$' );
			# $_ = $$_ if index($nexttype,'Class::Multimethods::SUPERCLASS')==0;
			$sig .= $nexttype;
			$sig .= ",";
		}
		chop $sig;

		my $code = $Class::Multimethods::dispatch{'NAME'}{$sig}
			|| $Class::Multimethods::cached{'NAME'}{$sig};
			 
		return $code->(@_) if ($code);

		my @types = split /,/, $sig;
		for (my $i=1; $i<@types; $i++)
		{
			$_[$i] = ${$_[$i]}
				if index($types[$i],'Class::Multimethods::SUPERCLASS')==0;
		}
		my %tried = ();	   # USED TO AVOID MULTIPLE MATCHES ON SAME SIG
		my @code;          # STORES LIST OF EQUALLY-CLOSE MATCHING SUBS
		my @candidates = ( [@types] );	# STORES POSSIBLE MATCHING SIGS

	# TRY AND RESOLVE TO AN TYPE-EXPLICIT SIGNATURE (USING INHERITANCE)

		1 until (Class::Multimethods::resolve('NAME',\@candidates,\@code,\%tried) || !@candidates);

	# IF THAT DOESN'T WORK, TRY A GENERIC SIGNATURE (IF THERE ARE ANY)
	# THE NESTED LOOPS GENERATE ALL POSSIBLE PERMUTATIONS OF GENERIC
	# SIGNATURES IN SUCH A WAY THAT, EACH TIME resolve IS CALLED, ALL
	# THE CANDIDATES ARE EQUALLY GENERIC (HAVE AN EQUAL NUMBER OF GENERIC
	# PLACEHOLDERS)

		if ( @code == 0 && $Class::Multimethods::hasgeneric{'NAME'} )
		{
			# TRY GENERIC VERSIONS
			my @gencandidates = ([@types]);
			GENERIC: for (0..$#types)
			{
				@candidates = ();
				for (my $gci=0; $gci<@gencandidates; $gci++)
				{
					for (my $i=0; $i<@types; $i++)
					{
						push @candidates,
						     [@{$gencandidates[$gci]}];
						$candidates[-1][$i] = "*";
					}
				}
				@gencandidates = @candidates;
				1 until (Class::Multimethods::resolve('NAME',\@candidates,\@code,\%tried) || !@candidates);
				last GENERIC if @code;
			}
		}

	# RESOLUTION PROCESS COMPLETED...
	# IF EXACTLY ONE BEST MATCH, CALL IT...

		if ( @code == 1 )
		{
			$Class::Multimethods::cached{'NAME'}{$sig} = $code[0];
			return $code[0]->(@_);
		}

	# TWO OR MORE EQUALLY LIKELY CANDIDATES IS AMBIGUOUS...
		elsif ( @code > 1)
		{
			my $handler = $Class::Multimethods::ambiguous_handler{'NAME'};
			if (defined $handler)
			{
				return $handler->(@_)
					if ref $handler;
				return $Class::Multimethods::dispatch{'NAME'}{$handler}->(@_)
					if defined $Class::Multimethods::dispatch{'NAME'}{$handler};
			}
			_prettify($sig);
			croak "Cannot resolve call to multimethod NAME($sig). " .
			      "The multimethods:\n" .
				join("\n",
				 map { "\tNAME(" . join(',',@$_) . ")" }
				  @candidates) .
				"\nare equally viable";
		}

	# IF *NO* CANDIDATE, NO WAY TO DISPATCH THE CALL
		else
		{
			my $handler = $Class::Multimethods::no_match_handler{'NAME'};
			if (defined $handler)
			{
				return $handler->(@_)
					if ref $handler;
				return $Class::Multimethods::dispatch{'NAME'}{$handler}->(@_)
					if defined $Class::Multimethods::dispatch{'NAME'}{$handler};
			}
			_prettify($sig);
			croak "No viable candidate for call to multimethod NAME($sig)";
		}
	}
	1;

	};
	$code =~ s/PACKAGE/$pkg/g;
	$code =~ s/NAME/$name/g;
	return $code;
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
		# print "trying @$candidate...\n";

	# BUILD THE TYPE SIGNATURE AND ENSURE IT HASN'T ALREADY BEEN CHECKED

     	 	my $sig = join ',', @$candidate;
		next if $tried->{$sig};
		$tried->{$sig} = 1;
	
	# LOOK FOR A MATCHING SUB REF IN THE DISPATCH TABLE AND REMEMBER IT...

		my $match = $Class::Multimethods::dispatch{$name}{$sig};
		if ($match && ref($match) eq 'CODE') 
		{
			push @$matches, $match;
			next;
		}

	# OTHERWISE, GENERATE A NEW SET OF CANDIDATES BY REPLACING EACH
	# ARGUMENT TYPE IN TURN BY EACH OF ITS IMMEDIATE PARENTS. EACH SUCH
	# NEW CANDIDATE MUST BE EXACTLY 1 DERIVATION MORE EXPENSIVE THAN
	# THE CURRENT GENERATION OF CANDIDATES. NOTE, THAT IF A MATCH HAS
	# BEEN FOUND AT THE CURRENT GENERATION, THERE IS NO NEED TO LOOK
	# ANY DEEPER...

		if (!@$matches)
		{
			for (my $i = 0; $i<@$candidate ; $i++)
			{
				next if $candidate->[$i] =~ /[^\w:#]/;
				no strict 'refs';
				my @parents;
				if ($candidate->[$i] eq '#')
					{ @parents = ('$') }
				elsif ($candidate->[$i] =~ /\AClass::Multimethods::SUPERCLASS_IS::(.+)/)
					{ @parents = ($1) }
				elsif ($candidate->[$i] =~ /\AClass::Multimethods::SUPERCLASS_OF::(.+)/)
					{ @parents = ($1 eq '#') ? '$' : @{$1."::ISA"} } 
				else
					{ @parents = @{$candidate->[$i]."::ISA"} } 
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

# SUPPORT FOR analyse

my %children;
my %parents;

sub build_relationships
{
	no strict "refs";
	%children = ( '$' => [ '#' ] );
	%parents  = ( '#' => [ '$' ] );
	my (@packages) = @_;
	foreach my $package (@packages)
	{
		foreach my $parent ( @{$package."::ISA"} )
		{
			push @{$children{$parent}}, $package;
			push @{$parents{$package}}, $parent;
		}
	}
}


sub list_packages
{
	no strict "refs";
	my $self = $_[0]||"main::";
	my @children = ( $self );
	foreach ( keys %{$self} )
	{
		next unless /::$/ && $_ ne $self;
		push @children, list_packages("$self$_")
	}
	@children = map { s/^main::(.+)$/$1/; s/::$//; $_ } @children
		unless $_[0];
	return @children;
}

sub list_ancestors
{
	my ($class) = @_;
	my @ancestors = ();
	foreach my $parent ( @{$parents{$class}} )
	{
		push @ancestors, list_ancestors($parent), $parent;
	}
	return @ancestors;
}

sub list_descendents
{
	my ($class) = @_;
	my @descendents = ();
	foreach my $child ( @{$children{$class}} )
	{
		push @descendents, $child, list_descendents($child);
	}
	return @descendents;
}

sub list_hierarchy
{
	my ($class) = @_;
	my @hierarchy = list_ancestors($class);
	push @hierarchy, $class;
	push @hierarchy, list_descendents($class);
	return @hierarchy;
}

@Class::Multimethods::dont_analyse = qw
(
	Exporter
	DynaLoader 
	AutoLoader
);

sub generate_argsets
{
	my ($multimethod) = @_;

	my %ignore;
	@ignore{@Class::Multimethods::dont_analyse} = ();


	return unless $min_args{$multimethod};

	my @paramlists = ();

	foreach my $typeset ( keys %{$Class::Multimethods::dispatch{$multimethod}} )
	{
		next if $typeset =~ /\Q*/;
		my @nexttypes = split /,/, $typeset;		
		for my $i (0..$#nexttypes)
		{
			for my $ancestor ( list_hierarchy $nexttypes[$i] )
			{
				$paramlists[$i]{$ancestor} = 1
					unless exists $ignore{$ancestor};
			}
		}
	}

	my @argsets = ();

	foreach (@paramlists) { $_ = [keys %{$_}] }

	use Data::Dumper;
	# print Data::Dumper->Dump([@paramlists]);

	foreach my $argcount ($min_args{$multimethod}..$max_args{$multimethod})
	{
		push @argsets, combinations(@paramlists[0..$argcount-1]);
	}

	# print STDERR Data::Dumper->Dump([@argsets]);

	return @argsets;
}

sub combinations
{
	my (@paramlists) = @_;
	return map { [$_] } @{$paramlists[0]} if (@paramlists==1);
	my @combs = ();
	my @subcombs = combinations(@paramlists[1..$#paramlists]);
	foreach my $firstparam (@{$paramlists[0]})
	{
		foreach my $subcomb ( @subcombs )
		{
			push @combs, [$firstparam, @{$subcomb}];
		}
	}
	return @combs;
}

sub analyse
{
	my ($multimethod, @argsets) = @_;
	my ($package,$file,$line) = caller(0);
	my ($sub) = (caller(1))[3] || "main code";
	my $case_count = @argsets;
	my $ambiguous_handler = $ambiguous_handler{$multimethod};
	my $no_match_handler = $no_match_handler{$multimethod};
	$ambiguous_handler = "$multimethod($ambiguous_handler)"
		if $ambiguous_handler && ref($ambiguous_handler) ne "CODE";
	$no_match_handler = "$multimethod($no_match_handler)"
		if $no_match_handler && ref($no_match_handler) ne "CODE";
	build_relationships list_packages;
	if ($case_count)
	{
		my @newargsets;
		foreach my $argset ( @argsets )
		{
			my @argset = map { ref eq 'ARRAY' ? $_ : [$_] } @$argset;
			push @newargsets, combinations(@argset);
		}
		@argsets = @newargsets;
		$case_count = @argsets;
	}
	else
	{
		@argsets = generate_argsets($multimethod);
		$case_count = @argsets;
		unless ($case_count)
		{
			print STDERR "[No variants found for $multimethod. No analysis possible.]\n\n";
	print STDERR "="x72, "\n\n";
			return;

		}
		print STDERR "[Generated $case_count test cases for $multimethod]\n\n"
	}

	print STDERR "Analysing calls to $multimethod from $sub ($file, line $line):\n";
	my $case = 1;

	my $successes = 0;
	my @fails = ();
	my @ambigs = ();

	foreach my $argset ( @argsets )
	{
		my $callsig = "${multimethod}(".join(",",@$argset).")";
		print STDERR "\n\t[$case/$case_count] For call to $callsig:\n\n";
		$case++;
		my @ordered = sort {
			     $a->{wrong_length} - $b->{wrong_length}
					       ||
				@{$a->{incomp}} - @{$b->{incomp}}
					       ||
				  $a->{generic} - $b->{generic}
					       ||
				$a->{sum_dist} <=> $b->{sum_dist}
					       }
				evaluate($multimethod, $argset);


		if ($ordered[0] && !@{$ordered[0]->{incomp}})
		{
			my $i;
			for ($i=1; $i<@ordered; $i++)
			{
				last if @{$ordered[$i]->{incomp}} ||
					$ordered[$i]->{wrong_length} ||
				        $ordered[$i]->{sum_dist} >
				        	$ordered[0]->{sum_dist} ||
				        $ordered[$i]->{generic} !=
				        	$ordered[0]->{generic};
			}
			$ordered[$_]->{less_viable} = 1 for ($i..$#ordered);
			if ($i>1)
			{
				$ordered[$i]->{ambig} = 1 while ($i-->0)
			}
		}

		my $first = 1;
		my $min_dist = 0;
		push @fails, "\t\t$callsig\n";  # ASSUME THE WORST

		# CHECK FOR REOLUTION IF DISPATCH FAILS

		my $winner = $ordered[0];
		if ($winner && $winner->{ambig} && $ambiguous_handler)
		{
			print STDERR "\t\t(+) $ambiguous_handler\n\t\t\t>>> Ambiguous dispatch handler invoked.\n\n";
			$first = 0;
			$successes++;
			pop @fails;
		}
		elsif ($winner
			    && (@{$winner->{incomp}} || $winner->{wrong_length})
			    && $no_match_handler )
		{
			print STDERR "\t\t(+) $no_match_handler\n\t\t\t>>> Dispatch failure handler invoked.\n\n";
			$first = 0;
			$successes++;
			pop @fails;
		}
		foreach my $variant (@ordered)
		{
			if ($variant->{ambig})
			{
				print STDERR "\t\t(?) $variant->{sig}\n\t\t\t>>> Ambiguous. Distance: $variant->{sum_dist}\n";
				push @ambigs, pop @fails if $first;
			}
			elsif (@{$variant->{incomp}} == 1)
			{
				print STDERR "\t\t(-) $variant->{sig}\n\t\t\t>>> Not viable. Incompatible argument: ", @{$variant->{incomp}}, "\n";
			}
			elsif (@{$variant->{incomp}})
			{
				print STDERR "\t\t(-) $variant->{sig}\n\t\t\t>>> Not viable. Incompatible arguments: ", join(",",@{$variant->{incomp}}), "\n";
			}
			elsif ($variant->{wrong_length})
			{
				print STDERR "\t\t(-) $variant->{sig}\n\t\t\t>>> Not viable. Wrong number of arguments\n";
			}
			elsif ($first)
			{
				print STDERR "\t\t(+) $variant->{sig}\n\t\t\t>>> Target. Distance: $variant->{sum_dist}\n\n";
				$min_dist = $variant->{sum_dist};
				$successes++;
				pop @fails;
			}
			elsif ($variant->{generic} && $variant->{sum_dist} < $min_dist)
			{
				print STDERR "\t\t(*) $variant->{sig}\n\t\t\t>>> Viable, but generic. Distance: $variant->{sum_dist} (generic)\n";
			}
			elsif ($variant->{generic})
			{
				print STDERR "\t\t(*) $variant->{sig}\n\t\t\t>>> Viable. Distance: $variant->{sum_dist} (generic)\n";
			}
			else
			{
				print STDERR "\t\t(x) $variant->{sig}\n\t\t\t>>> Viable. Distance: $variant->{sum_dist}\n";
			}
			$first = 0;
		}
		print STDERR "\n";
	}
	print STDERR "\n", "-"x72, "\nSummary for calls to $multimethod from $sub ($file, line $line):\n\n";

	printf STDERR "\tSuccessful dispatch in %2.0f%% of calls\n",
			$successes/$case_count*100;
	printf STDERR "\tDispatch ambiguous for %2.0f%% of calls\n",
			@ambigs/$case_count*100;
	printf STDERR "\tWas unable to dispatch %2.0f%% of calls\n",
			@fails/$case_count*100;

	print STDERR "\nAmbiguous calls:\n", @ambigs if @ambigs;
	print STDERR "\nUndispatchable:\n", @fails if @fails;

	print STDERR "\n", "="x72, "\n\n";

}

my %distance;
sub distance
{
	my ($from, $to) = @_;

	return 0 if $from eq $to;
	return -1 if $to eq '*';
	return $distance{$from}{$to} if defined $distance{$from}{$to};

	if ($parents{$from})
	{
		foreach my $parent ( @{$parents{$from}} )
		{
			my $distance = distance($parent,$to);
			if (defined $distance)
			{
				$distance{$from}{$to} = $distance+1;
				return $distance+1;
			}
		}
	}
	return undef;
}

sub evaluate
{
	my ($name, $types) = @_;
	my @results = ();
	my $sig = join ',', @$types;

	SET: foreach my $typeset ( keys %{$Class::Multimethods::dispatch{$name}} )
	{
		
		push @results, { sig      	=> "$name($typeset)",
				 incomp   	=> [],
				 sum_dist	=> 0,
				 wrong_length	=> 0,
				 generic	=> 0,
			       };
		my @nexttypes = split /,/, $typeset;		
		if (@nexttypes != @$types)
		{
			$results[-1]->{wrong_length} = 1;
			next SET;
		}

		my @dist;
		PARAM: for (my $i=0; $i<@$types; $i++)
		{
			my $nextdist = distance($types->[$i], $nexttypes[$i]);
			push @{$results[-1]->{dist}}, $nextdist;
			if (!defined $nextdist)
			{
				push @{$results[-1]->{incomp}}, $i;
			}
			elsif ($nextdist < 0)
			{
				$results[-1]->{generic} = 1;
			}
			else
			{
				$results[-1]->{sum_dist} += $nextdist
			}
		}
	}
	return @results;
}


1;
__END__

