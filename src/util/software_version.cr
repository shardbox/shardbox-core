# The `Version` type represents a version number.
#
# An instance can be created from a version string which consists of a series of
# segments separated by periods. Each segment contains one ore more alpanumerical
# ASCII characters. The first segment is expected to contain only digits.
#
# There may be one instance of a dash (`-`) which denotes the version as a
# pre-release. It is otherwise equivalent to a period
#
# This format is described by the regular expression:
# `/[0-9]+(?>\.[0-9a-zA-Z]+)*(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?/`
#
# This implementation is compatible to popular versioning schemes such as
# [`SemVer`](https://semver.org/) and [`CalVer`](https://calver.org/) but
# doesn't enforce any particular one.
#
# It behaves mostly equivalent to [`Gem::Version`](http://docs.seattlerb.org/rubygems/Gem/Version.html) from `rubygems`.
#
# ## Sort order
# This wrapper type is mostly important for properly sorting version numbers,
# because generic lexical sorting doesn't work: For instance, `3.10` is supposed
# to be greater than `3.2`.
#
# Every set of consecutive digits anywhere in the string are interpreted as a
# decimal number and numerically sorted. Letters are lexically sorted.
# Periods (and dash) delimit numbers but don't effect sort order by themselves.
# Thus `1.0a` is equal to `1.0.a`.
#
# ## Pre-release
# If a version number contains a letter (`a-z`) then that version is considered
# a pre-release. Pre-releases sort lower than the rest of the version prior to
# the first letter (or dash). For instance `1.0-b` compares lower than `1.0` but
# greater than `1.0-a`.
struct SoftwareVersion
  include Comparable(self)
  include Comparable(String)

  # :nodoc:
  VERSION_PATTERN = /[0-9]+(?>\.[0-9a-zA-Z]+)*(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?/
  # :nodoc:
  ANCHORED_VERSION_PATTERN = /\A\s*(#{VERSION_PATTERN})\s*\z/

  @string : String

  # Returns `true` if *string* is a valid version format.
  def self.valid?(string : String) : Bool
    !ANCHORED_VERSION_PATTERN.match(string).nil?
  end

  # Constructs a `Version` from *string*. A version string is a
  # series of digits or ASCII letters separated by dots.
  def initialize(string : String)
    # If string is an empty string convert it to 0
    string = "0" if string =~ /\A\s*\Z/

    unless self.class.valid?(string)
      raise ArgumentError.new("Malformed version string #{string.inspect}")
    end

    @string = string.strip
  end

  # Constructs a `Version` from the string representation of *version* number.
  def self.new(version : Number)
    new(version.to_s)
  end

  # Appends the string representation of this version to *io*.
  def to_s(io : IO)
    io << @string
  end

  # Returns the string representation of this version.
  def to_s : String
    @string
  end

  # Returns `true` if this version is a pre-release version.
  #
  # A version is considered pre-release if it contains an ASCII letter or `-`.
  #
  # ```
  # SoftwareVersion.new("1.0.0").prerelease?     # => false
  # SoftwareVersion.new("1.0.0-dev").prerelease? # => true
  # SoftwareVersion.new("1.0.0-1").prerelease?   # => true
  # SoftwareVersion.new("1.0.0a1").prerelease?   # => true
  # ```
  def prerelease? : Bool
    @string.each_char do |char|
      if char.ascii_letter? || char == '-'
        return true
      end
    end

    false
  end

  # Returns version representing the release version associated with this version.
  #
  # If this version is a pre-release (see `#prerelease?`) a new instance will be created
  # with the same version string before the first ASCII letter or `-`.
  #
  # Otherwise returns `self`.
  #
  # ```
  # SoftwareVersion.new("1.0.0").release     # => SoftwareVersion.new("1.0.0")
  # SoftwareVersion.new("1.0.0-dev").release # => SoftwareVersion.new("1.0.0")
  # SoftwareVersion.new("1.0.0-1").release   # => SoftwareVersion.new("1.0.0")
  # SoftwareVersion.new("1.0.0a1").release   # => SoftwareVersion.new("1.0.0")
  # ```
  def release : self
    @string.each_char_with_index do |char, index|
      if char.ascii_letter? || char == '-'
        return self.class.new(@string.byte_slice(0, index - 1))
      end
    end

    self
  end

  # Compares this version with an instance created from *other* returning
  # -1, 0, or 1 if the other version is larger, the same, or smaller than this one.
  def <=>(other : String)
    self <=> self.class.new(other)
  end

  # Compares this version with *other* returning -1, 0, or 1 if the
  # other version is larger, the same, or smaller than this one.
  def <=>(other : self)
    lstring = @string
    rstring = other.@string
    lindex = 0
    rindex = 0

    while true
      lchar = lstring.byte_at?(lindex).try &.chr
      rchar = rstring.byte_at?(rindex).try &.chr

      # Both strings have been entirely consumed, they're identical
      return 0 if lchar.nil? && rchar.nil?

      ldelimiter = {'.', '-'}.includes?(lchar)
      rdelimiter = {'.', '-'}.includes?(rchar)

      # Skip delimiters
      lindex += 1 if ldelimiter
      rindex += 1 if rdelimiter
      next if ldelimiter || rdelimiter

      # If one string is consumed, the other is either ranked higher (char is a digit)
      # or lower (char is letter, making it a pre-release tag).
      if lchar.nil?
        return rchar.not_nil!.ascii_letter? ? 1 : -1
      elsif rchar.nil?
        return lchar.ascii_letter? ? -1 : 1
      end

      # Try to consume consequitive digits into a number
      lnumber, new_lindex = consume_number(lstring, lindex)
      rnumber, new_rindex = consume_number(rstring, rindex)

      # Proceed depending on where a number was found on each string
      case {new_lindex != lindex, new_rindex != rindex}
      when {true, true}
        # Both strings have numbers at current position.
        # They are compared (numerical) and the algorithm only continues if they
        # are equal.
        ret = lnumber <=> rnumber
        return ret unless ret == 0
      when {true, false}
        # Left hand side has a number, right hand side a letter (and thus a pre-release tag)
        return -1
      when {false, true}
        # Right hand side has a number, left hand side a letter (and thus a pre-release tag)
        return 1
      when {false, false}
        # Both strings have a letter at current position.
        # They are compared (lexical) and the algorithm only continues if they
        # are equal.
        ret = lchar <=> rchar
        return ret unless ret == 0
      end

      # Move to the next position in both strings
      lindex = new_lindex
      rindex = new_rindex
    end
  end

  # Helper method to read a sequence of digits from *string* starting at
  # position *index* into an integer number.
  # It returns the consumed number and index position.
  private def consume_number(string : String, index : Int32)
    number = 0
    while (byte = string.byte_at?(index)) && byte.chr.ascii_number?
      number *= 10
      number += byte
      index += 1
    end
    {number, index}
  end

  def self.compare(a : String, b : String)
    new(a) <=> new(b)
  end

  def matches_pessimistic_version_constraint?(constraint : String)
    constraint = self.class.new(constraint).release.to_s

    if last_period_index = constraint.rindex('.')
      constraint_lead = constraint.[0...last_period_index]
    else
      constraint_lead = constraint
    end
    last_period_index = constraint_lead.bytesize

    # Compare the leading part of the constraint up until the last period.
    # If it doesn't match, the constraint is not fulfilled.
    return false unless @string.starts_with?(constraint_lead)

    # The character following the constraint lead can't be a number, otherwise
    # `0.10` would match `0.1` because it starts with the same three characters
    next_char = @string.byte_at?(last_period_index).try &.chr
    return true unless next_char
    return false if next_char.ascii_number?

    # We've established that constraint is met up until the second-to-last
    # segment.
    # Now we only need to ensure that the last segment is actually bigger than
    # the constraint so that `0.1` doesn't match `~> 0.2`.
    # self >= constraint
    constraint_number, _ = consume_number(constraint, last_period_index + 1)
    own_number, _ = consume_number(@string, last_period_index + 1)

    own_number >= constraint_number
  end

  # Custom hash implementation which produces the same hash for `a` and `b` when `a <=> b == 0`
  def hash(hasher)
    string = @string
    index = 0

    while byte = string.byte_at?(index)
      if {'.'.ord, '-'.ord}.includes?(byte)
        index += 1
        next
      end

      number, new_index = consume_number(string, index)

      if new_index != index
        hasher.int(number)
        index = new_index
      else
        hasher.int(byte)
      end
      index += 1
    end

    hasher
  end
end
