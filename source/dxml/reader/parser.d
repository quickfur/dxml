// Written in the D programming language

/++
    Copyright: Copyright 2017
    License:   $(WEB www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   Jonathan M Davis
    Source:    $(LINK_TO_SRC dxml/reader/_parser.d)
  +/
module dxml.reader.parser;

import std.algorithm : equal, startsWith;
import std.range.primitives;
import std.range : takeExactly;
import std.traits;
import std.typecons : Flag, Nullable, nullable;
import std.utf : byCodeUnit, decodeFront, UseReplacementDchar;

import dxml.reader.internal;

/++
    The exception type thrown when the XML parser runs into invalid XML.
  +/
class XMLParsingException : Exception
{
    /++
        The position in the XML input where the problem is.

        How informative it is depends on the $(LREF PositionType) used when
        parsing the XML.
      +/
    SourcePos pos;

package:

    this(string msg, SourcePos sourcePos, string file = __FILE__, size_t line = __LINE__)
    {
        pos = sourcePos;
        super(msg, file, line);
    }
}


/++
    Where in the XML text an entity is. If the $(LREF PositionType) when
    parsing does not keep track of a given field, then that field will always be
    $(D -1).
  +/
struct SourcePos
{
    /// A line number in the XML file.
    int line = -1;

    /++
        A column number in a line of the XML file.

        Each code unit is considered a column, so depending on what a program
        is looking to do with the column number, it may need to examine the
        actual text on that line and calculate the number that represents
        what the program wants to display (e.g. the number of graphemes).
      +/
    int col = -1;
}


/++
    At what level of granularity the position in the XML file should be kept
    track of (it's used in $(LREF XMLParsingException) to indicate where the
    in the text the invalid XML was found). $(LREF _PositionType.none) is the
    most efficient but least informative, whereas
    $(LREF _PositionType.lineAndCol) is the most informative but least
    efficient.
  +/
enum PositionType
{
    /// Both the line number and the column number are kept track of.
    lineAndCol,

    /// The line number is kept track of but not the column.
    line,

    /// The position is not tracked.
    none,
}


/++
    Used to configure how the parser works.

    See_Also:
        $(LREF makeConfig)$(BR)
        $(LREF parseXML)
  +/
struct Config
{
    /++
        Whether the comments should be skipped while parsing.

        If $(D true), any entities of type $(LREF EntityType.comment) will be
        omitted from the parsing results.

        Defaults to $(D SkipComments.no).
      +/
    auto skipComments = SkipComments.no;

    /++
        Whether the `<!DOCTYPE ... >` entities should be skipped while parsing.

        If $(D true), any entities of type $(LREF EntityType.dtdStartTag) and
        $(LREF EntityType.dtdEndTag) and any entities in between will be omitted
        from the parsing results.

        Defaults to $(D SkipDTD.no).
      +/
    auto skipDTD = SkipDTD.no;

    /++
        Whether the prolog should be skipped while parsing.

        If $(D true), any entities prior to the root element will omitted
        from the parsing results.

        Defaults to $(D SkipProlog.no).
      +/
    auto skipProlog = SkipProlog.no;

    /++
        Whether processing instructions should be skipped.

        If $(D true), any entities with the type
        $(LREF EntityType.processingInstruction) will be skipped.

        Defaults to $(D SkipPI.no).
      +/
    auto skipPI = SkipPI.no;

    /++
        Whether $(LREF EntityType.text) entities that contain only whitespace
        will be skipped.

        With $(LREF SkipContentWS.no), XML that is formatted with indenting and
        newlines and the like will contain lots of $(LREF EntityType.text)
        entities which are just whitespace, but with $(LREF SkipContentWS.yes),
        all of the formatting is lost when parsing, and if the program wants to
        treat that whitespace as significant, then it has a problem. Which is
        better of course depends on what the application is doing when parsing
        the XML.

        However, note that $(I some) formatting will be lost regardless,
        because any whitespace which is not part of an $(LREF EntityType.text)
        entity will be parsed without being communicated to the program
        (e.g. the program using $(LREF parseXML) won't know what whitespace
        was between $(LREF EntityType.processingInstruction) entities and won't
        know what kind of whitespace or how much there was between the name of
        a start tag and its attributes).

        Note that XML only considers $(D ' '), $(D '\t'), $(D '\n'), and
        $(D '\r') to be whitespace. So, those are the only character skipped
        with $(LREF StripContentsWS.yes), and those are the characters that
        $(LREF EntityParser) expects at any point in the XML that is supposed
        to contain whitespace.

        Defaults to $(D SkipContentWS.yes).

        See_Also: $(LREF EntityParser.text)
      +/
    auto skipContentWS = SkipContentWS.yes;

    /++
        Whether the parser should report empty element tags as if they were a
        start tag followed by an end tag with nothing in between.

        If $(D true), then whenever an $(LREF EntityType.elementEmpty) is
        encountered, the parser will claim that that entity is an
        $(LREF EntityType.elementStart), and then it will provide an
        $(LREF EntityType.elementEnd) as the next entity before the entity that
        actually follows it.

        The purpose of this is to simplify the code using the parser, since most
        code does not care about the difference between an empty tag and a start
        and end tag with nothing in between. But since some code will care about
        the difference, the behavior is configurable rather than simply always
        treating them as the same.

        Defaults to $(D SplitEmpty.no).
      +/
    auto splitEmpty = SplitEmpty.no;

    ///
    unittest
    {
        enum configSplitYes = makeConfig(SplitEmpty.yes);

        {
            auto parser = parseXML("<root></root>");
            assert(parser.type == EntityType.elementStart);
            assert(parser.name == "root");
            parser.next();
            assert(parser.type == EntityType.elementEnd);
            assert(parser.name == "root");
            parser.next();
            assert(parser.empty);
        }
        {
            // No difference if the tags are already split.
            auto parser = parseXML!configSplitYes("<root></root>");
            assert(parser.type == EntityType.elementStart);
            assert(parser.name == "root");
            parser.next();
            assert(parser.type == EntityType.elementEnd);
            assert(parser.name == "root");
            parser.next();
            assert(parser.empty);
        }
        {
            // This treats <root></root> and <root/> as distinct.
            auto parser = parseXML("<root/>");
            assert(parser.type == EntityType.elementEmpty);
            assert(parser.name == "root");
            parser.next();
            assert(parser.empty);
        }
        {
            // This is parsed as if it were <root></root> insead of <root/>.
            auto parser = parseXML!configSplitYes("<root/>");
            assert(parser.type == EntityType.elementStart);
            assert(parser.name == "root");
            parser.next();
            assert(parser.type == EntityType.elementEnd);
            assert(parser.name == "root");
            parser.next();
            assert(parser.empty);
        }
    }

    /++
        This affects how precise the position information is in
        $(LREF XMLParsingException)s that get thrown when invalid XML is
        encountered while parsing.

        Defaults to $(LREF PositionType.lineAndCol).

        See_Also: $(LREF PositionType)$(BR)$(LREF SourcePos)
      +/
    PositionType posType = PositionType.lineAndCol;
}


/// See_Also: $(LREF2 skipComments, Config)
alias SkipComments = Flag!"SkipComments";

/// See_Also: $(LREF2 skipDTD, Config)
alias SkipDTD = Flag!"SkipDTD";

/// See_Also: $(LREF2 skipProlog, Config)
alias SkipProlog = Flag!"SkipProlog";

/// See_Also: $(LREF2 skipPI, Config)
alias SkipPI = Flag!"SkipPI";

/// See_Also: $(LREF2 skipContentWS, Config)
alias SkipContentWS = Flag!"SkipContentWS";

/// See_Also: $(LREF2 splitEmpty, Config)
alias SplitEmpty = Flag!"SplitEmpty";


/++
    Helper function for creating a custom config. It makes it easy to set one
    or more of the member variables to something other than the default without
    having to worry about explicitly setting them individually or setting them
    all at once via a constructor.

    The order of the arguments does not matter. The types of each of the members
    of Config are unique, so that information alone is sufficient to determine
    which argument should be assigned to which member.
  +/
Config makeConfig(Args...)(Args args)
{
    import std.format : format;
    import std.meta : AliasSeq, staticIndexOf, staticMap;

    template isValid(T, Types...)
    {
        static if(Types.length == 0)
            enum isValid = false;
        else static if(is(T == Types[0]))
            enum isValid = true;
        else
            enum isValid = isValid!(T, Types[1 .. $]);
    }

    Config config;

    alias TypeOfMember(string memberName) = typeof(__traits(getMember, config, memberName));
    alias MemberTypes = staticMap!(TypeOfMember, AliasSeq!(__traits(allMembers, Config)));

    foreach(i, arg; args)
    {
        static assert(isValid!(typeof(arg), MemberTypes),
                      format!"Argument %s does not match the type of any members of Config"(i));

        static foreach(j, Other; Args)
        {
            static if(i != j)
                static assert(!is(typeof(arg) == Other), format!"Argument %s and %s have the same type"(i, j));
        }

        foreach(memberName; __traits(allMembers, Config))
        {
            static if(is(typeof(__traits(getMember, config, memberName)) == typeof(arg)))
                mixin("config." ~ memberName ~ " = arg;");
        }
    }

    return config;
}

///
@safe pure nothrow @nogc unittest
{
    {
        auto config = makeConfig(SkipComments.yes);
        assert(config.skipComments == SkipComments.yes);
        assert(config.skipDTD == Config.init.skipDTD);
        assert(config.skipProlog == Config.init.skipProlog);
        assert(config.skipPI == Config.init.skipPI);
        assert(config.skipContentWS == Config.init.skipContentWS);
        assert(config.splitEmpty == Config.init.splitEmpty);
        assert(config.posType == Config.init.posType);
    }
    {
        auto config = makeConfig(SkipComments.yes, PositionType.none);
        assert(config.skipComments == SkipComments.yes);
        assert(config.skipDTD == Config.init.skipDTD);
        assert(config.skipProlog == Config.init.skipProlog);
        assert(config.skipPI == Config.init.skipPI);
        assert(config.skipContentWS == Config.init.skipContentWS);
        assert(config.splitEmpty == Config.init.splitEmpty);
        assert(config.posType == PositionType.none);
    }
    {
        auto config = makeConfig(SplitEmpty.yes,
                                 SkipComments.yes,
                                 PositionType.line);
        assert(config.skipComments == SkipComments.yes);
        assert(config.skipDTD == Config.init.skipDTD);
        assert(config.skipProlog == Config.init.skipProlog);
        assert(config.skipPI == Config.init.skipPI);
        assert(config.skipContentWS == Config.init.skipContentWS);
        assert(config.splitEmpty == SplitEmpty.yes);
        assert(config.posType == PositionType.line);
    }
}

unittest
{
    import std.typecons : Flag;
    static assert(!__traits(compiles, makeConfig(42)));
    static assert(!__traits(compiles, makeConfig("hello")));
    static assert(!__traits(compiles, makeConfig(Flag!"SomeOtherFlag".yes)));
    static assert(!__traits(compiles, makeConfig(SplitEmpty.yes, SplitEmpty.no)));
}


/++
    This config is intended for making it easy to parse XML that does not
    contain some of the more advanced XML features such as DTDs. It skips
    everything that can be configured to skip.
  +/
enum simpleXML = makeConfig(SkipComments.yes, SkipDTD.yes, SkipProlog.yes, SkipPI.yes,
                            SplitEmpty.yes, PositionType.lineAndCol);

///
@safe pure nothrow @nogc unittest
{
    static assert(simpleXML.skipComments == SkipComments.yes);
    static assert(simpleXML.skipDTD == SkipDTD.yes);
    static assert(simpleXML.skipProlog == SkipProlog.yes);
    static assert(simpleXML.skipPI == SkipPI.yes);
    static assert(simpleXML.skipContentWS == SkipContentWS.yes);
    static assert(simpleXML.splitEmpty == SplitEmpty.yes);
    static assert(simpleXML.posType == PositionType.lineAndCol);
}


/++
    Represents the type of an XML entity. Used by EntityParser.
  +/
enum EntityType
{
    /++
        The `<!ATTLIST ... >` tag.

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#attdecls)
      +/
    attlistDecl,

    /++
        A cdata section: `<![CDATA[ ... ]]>`.

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#sec-cdata-sect)
      +/
    cdata,

    /++
        An XML comment: `<!-- ... -->`.

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#sec-comments)
      +/
    comment,

    /++
        The beginning of a `<!DOCTYPE ... >` tag.

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#sec-prolog-dtd)
      +/
    docTypeStart,

    /++
        The `>` indicating the end of a `<!DOCTYPE` tag.

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#sec-prolog-dtd)
      +/
    docTypeEnd,

    /++
        The `<!ELEMENT ... >` tag.

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#elemdecls)
      +/
    elementTypeDecl,

    /++
        The start tag for an element. e.g. `<foo name="value">`.

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#sec-starttags)
      +/
    elementStart,

    /++
        The end tag for an element. e.g. `</foo>`.

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#sec-starttags)
      +/
    elementEnd,

    /++
        The tag for an element with no contents. e.g. `<foo name="value"/>`.

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#sec-starttags)
      +/
    elementEmpty,

    /++
        The `<!ENTITY ... >` tag.

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#sec-entity-decl)
      +/
    entityDecl,

    /++
        The `<!NOTATION ... >` tag.

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#Notations)
      +/
    notationDecl,

    /++
        A processing instruction such as `<?foo?>`. Note that
        `<?xml ... ?>` is an $(LREF EntityType.xmlDecl) and not an
        $(LREF EntityType.processingInstruction).

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#sec-pi)
      +/
    processingInstruction,

    /++
        The content of an element tag that is simple text.

        If there is an entity other than the end tag following the text, then
        the text includes up to that entity.

        Note however that character references (e.g. $(D "&#42")) and entity
        references (e.g. $(D "&Name;")) are left unprocessed in the text
        (primarily because the most user-friendly thing to do with
        them is to convert them in place, and that's best to a higher level
        parser or helper function).

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#sec-starttags)
      +/
    text,

    /++
        The `<?xml ... ?>` entity that can start an XML 1.0 document and must
        start an XML 1.1 document.

        See_Also: $(LINK http://www.w3.org/TR/REC-xml/#sec-prolog-dtd)
      +/
    xmlDecl
}


/++
    Lazily parses the given XML.

    EntityParser is essentially a
    $(LINK2 https://en.wikipedia.org/wiki/StAX, StAX) parser, though it evolved
    into that rather than being based on what Java did, so its API is likely
    to differ from other implementations.

    The resulting EntityParser is similar to an input range with how it's
    iterated until it's consumed, and its state cannot be saved (since
    unfortunately, saving would essentially require duplicating the entire
    parser, including all of the memory that it's allocated), but because there
    are essentially multiple ways to pop the front (e.g. choosing to skip all of
    the contents between a start tag and end tag instead of processing it), the
    input range API didn't seem to appropriate, even if the result functions
    similarly.

    Also, unlike a range the, "front" is integrated into the EntityParser rather
    than being a value that can be extracted. So, while an entity can be queried
    while it is the "front", it can't be kept around after the EntityParser has
    moved to the next entity. Only the information that has been queried for
    that entity can be retained (e.g. its $(LREF2 name, _EntityParser),
    $(LREF2 attributes, _EntityParser), or $(LREF2 text, _EntityParser)ual value).
    While that does place some restrictions on how an algorithm operating on an
    EntityParser can operate, it does allow for more efficient processing.

    If invalid XML is encountered at any point during the parsing process, an
    $(LREF XMLParsingException) will be thrown.

    However, note that EntityParser does not generally care about XML validation
    beyond what is required to correctly parse what it has been told to parse.
    In particular, any portions that are skipped (either due to the values in
    the $(LREF Config) or because a function such as
    $(LREF2 skipContents, _EntityParser) is called) will only be validated
    enough to correctly determine where those portions terminated. Similarly,
    if the functions to process the value of an entity are not called (e.g.
    $(LREF2 attributes, _EntityParser) for $(LREF EntityType.elementStart) and
    $(LREF2 xmlSpec, _EntityParser) for $(LREF EntityType.xmlSpec)), then those
    portions of the XML will not be validated beyond what is required to iterate
    to the next entity.

    A possible enhancement would be to add a $(D validateXML) function that
    corresponds to parseXML and fully validates the XML, but for now, no such
    function exists.

    EntityParser is a reference type.

    Note that while EntityParser is not $(D @nogc), it is designed to allocate
    very miminally. The parser state is allocated on the heap so that it is a
    reference type, and it has to allocate on the heap to retain a stack of the
    names of element tags so that it can validate the XML properly as well as
    provide the full path for a given entity, but it does no allocation
    whatsoever with the text that it's given. It operates entirely on slices
    (or the result of $(PHOBOS_REF takeExactly, std, range)), and that's what
    it returns from any function that returns a portion of the XML. Helper
    functions (such as $(LREF cleanText)) may allocate, but if so, their
    documentation makes that clear. The only other case where it may allocate
    is when throwing an $(LREF XMLException).

    See_Also: $(MOD_REF dxml, reader, dom)
  +/
struct EntityParser(Config cfg, R)
    if(isForwardRange!R && isSomeChar!(ElementType!R))
{
public:

    import std.algorithm : canFind;
    import std.range : only;

    private enum compileInTests = is(R == EntityCompileTests);

    /// The Config used for this parser.
    alias config = cfg;

    /++
        The type used when any slice of the original text is used. If $(D R)
        is a string or supports slicing, then SliceOfR is the same as $(D R);
        otherwise, it's the result of calling
        $(PHOBOS_REF takeExactly, std, range) on the text.
      +/
    static if(isDynamicArray!R || hasSlicing!R)
        alias SliceOfR = R;
    else
        alias SliceOfR = typeof(takeExactly(R.init, 42));

    // TODO re-enable these. Whenever EntityParser doesn't compile correctly due
    // to a change, these static assertions fail, and the actual errors are masked.
    // So, rather than continuing to deal with that whenever I change somethnig,
    // I'm leaving these commented out for now.
    // Also, unfortunately, https://issues.dlang.org/show_bug.cgi?id=11133
    // currently prevents this from showing up in the docs, and I don't know of
    // a workaround that works.
    /+
    ///
    static if(compileInTests) @safe unittest
    {
        import std.algorithm : filter;
        import std.range : takeExactly;

        static assert(is(EntityParser!(Config.init, string).SliceOfR == string));

        auto range = filter!(a => true)("some xml");

        static assert(is(EntityParser!(Config.init, typeof(range)).SliceOfR ==
                         typeof(takeExactly(range, 4))));
    }
    +/


    /++
        The type of the current entity.

        The value of this member determines which member functions and
        properties are allowed to be called, since some are only appropriate
        for specific entity types (e.g. $(LREF2 attributes, EntityParser) would
        not be appropriate for $(LREF EntityType.elementEnd)).
      +/
    @property EntityType type()
    {
        return _state.type;
    }


    /++
        Move to the next entity.

        The next entity is the next one that is linearly in the XML document.
        So, if the current entity has child entities, the next entity will be
        the child entity, whereas if it has no child entities, it will be the
        next entity at the same level.
      +/
    void next()
    {
        while(1)
        {
            final switch(_state.grammarPos) with(GrammarPos)
            {
                case prologMisc1:
                {
                    _parseAtPrologMisc!1();
                    static if(config.skipProlog == SkipProlog.yes)
                    {
                        if(_state.grammarPos <= intSubset)
                            continue;
                    }
                    break;
                }
                case prologMisc2:
                {
                    _parseAtPrologMisc!2();
                    static if(config.skipProlog == SkipProlog.yes)
                    {
                        if(_state.grammarPos <= intSubset)
                            continue;
                    }
                    break;
                }
                case intSubset:
                {
                    assert(0);
                    //break;
                }
                case splittingEmpty:
                {
                    _state.type = EntityType.elementEnd;
                    _state.grammarPos = _state.tagStack.empty ? GrammarPos.endMisc : GrammarPos.contentCharData2;
                    break;
                }
                case contentCharData1:
                {
                    assert(_state.type == EntityType.elementStart);
                    _state.tagStack.push(_state.name);
                    _parseAtContentCharData();
                    break;
                }
                case contentMid: _parseAtContentMid(); break;
                case contentCharData2: _parseAtContentCharData(); break;
                case endTag: _parseElementEnd(); break;
                case endMisc: _parseAtEndMisc(); break;
                case documentEnd: assert(0, "It's invalid to call next when the EntityParser is empty");
            }
            return;
        }
    }


    /++
        $(D true) if there is no more XML to process. It as an error to call
        $(D next) once empty is $(D true).
      +/
    bool empty()
    {
        return _state.grammarPos == GrammarPos.documentEnd;
    }


    /++
        Gives the name of the current entity.

        Note that this is the direct name in the XML for this entity and does
        not contain any of the names of any of the parent entities that this
        entity has.

        $(TABLE
            $(TR $(TH Supported $(LREF EntityType)s:))
            $(TR $(TD $(LREF2 docTypeStart, EntityType)))
            $(TR $(TD $(LREF2 elementStart, EntityType)))
            $(TR $(TD $(LREF2 elementEnd, EntityType)))
            $(TR $(TD $(LREF2 elementEmpty, EntityType)))
            $(TR $(TD $(LREF2 processingInstruction, EntityType)))
        )

        See_Also: $(LREF path, EntityParser)$(BR)$(LREF parentPath, EntityParser)
      +/
    @property SliceOfR name()
    {
        with(EntityType)
            assert(only(docTypeStart, elementStart, elementEnd, elementEmpty, processingInstruction).canFind(type));

        return stripBCU!R(_state.name);
    }


    /++
        Gives the path of the current entity as a lazy range.

        Unlike $(LREF2 name, EntityParser), this includes the names of all of
        the parent entities. The path does not take into account the fact that
        there may be multiple entities with the same path (e.g. a start tag
        could have multiple start tags in its contents which have the same
        name). The path is simply the list of the names of the parent tags plus
        the name of the current tag.

        Note that the range returned by path is only valid until
        $(LREF next, EntityParser) is called. Each element in the range will
        continue to be valid, but the range itself will not be (since the range
        refers to the internal stack of tag names, which can change when
        $(LREF next, EntityParser) is called).

        $(TABLE
            $(TR $(TH Supported $(LREF EntityType)s:))
            $(TR $(TD $(LREF2 docTypeStart, EntityType)))
            $(TR $(TD $(LREF2 elementStart, EntityType)))
            $(TR $(TD $(LREF2 elementEnd, EntityType)))
            $(TR $(TD $(LREF2 elementEmpty, EntityType)))
            $(TR $(TD $(LREF2 processingInstruction, EntityType)))
         )

        See_Also: $(LREF name, EntityParser)$(BR)$(LREF parentPath, EntityParser)
      +/
    @property auto path()
    {
        with(EntityType)
            assert(only(docTypeStart, elementStart, elementEmpty, elementEnd, processingInstruction).canFind(type));

        assert(0);
    }


    /++
        Gives the path of the parent entity as a lazy range.

        Unlike $(LREF2 name, EntityParser), this includes the names of all of
        the parent entities. However, unlike $(LREF2 name, EntityParser) and
        $(LREF2 path, EntityParser), parentPath works with all entity types
        (though in the case of root-level elements, it will be empty). Like
        (LREF2 path, EntityParser), no effort is made to make the path unique.
        It is simply a list of the names of the parent tags.

        Note that the range returned by parentPath is only valid until
        $(LREF next, EntityParser) is called. Each element in the range will
        continue to be valid, but the range itself will not be (since the range
        refers to the internal stack of tag names, which can change when
        $(LREF next, EntityParser) is called).

        See_Also: $(LREF name, EntityParser)$(BR)$(LREF path, EntityParser)
      +/
    @property auto parentPath()
    {
        with(EntityType)
            assert(only(docTypeStart, elementStart, elementEnd, elementEmpty, processingInstruction).canFind(type));

        assert(0);
    }


    /++
        Returns a lazy range of attributes for a start tag where each attribute
        is represented as a
        $(D Tuple!($(LREF2 SliceOfR, EntityParser), "name", $(LREF2 SliceOfR, EntityParser), "value")).

        $(TABLE
            $(TR $(TH Supported $(LREF EntityType)s:))
            $(TR $(TD $(LREF2 elementStart, EntityType)))
            $(TR $(TD $(LREF2 elementEmpty, EntityType)))
        )
      +/
    @property auto attributes()
    {
        with(EntityType)
            assert(only(elementStart, elementEmpty).canFind(type));

        // STag         ::= '<' Name (S Attribute)* S? '>'
        // Attribute    ::= Name Eq AttValue
        // EmptyElemTag ::= '<' Name (S Attribute)* S? '/>'

        import std.typecons : Tuple;
        alias Attribute = Tuple!(SliceOfR, "name", SliceOfR, "value");

        static struct Range
        {
            @property Attribute front()
            {
                assert(!empty);
                return _front;
            }

            void popFront()
            {
                if(_text.input.empty)
                {
                    empty = true;
                    return;
                }

                auto state = &_text;
                auto pos = state.pos;

                auto name = stripBCU!R(state.takeName!'='());
                stripWS(state);

                auto value = stripBCU!R(takeEnquotedText(state));
                stripWS(state);

                _front = Attribute(name, value);
            }

            @property auto save()
            {
                auto retval = this;
                retval._front = Attribute(_front[0].save, _front[1].save);
                retval._text.input = retval._text.input.save;
                return retval;
            }

            this(typeof(_text) text)
            {
                _front = Attribute.init; // This is utterly stupid. https://issues.dlang.org/show_bug.cgi?id=13945
                _text = text;
                if(_text.input.empty)
                    empty = true;
                else
                    popFront();
            }

            bool empty;
            Attribute _front;
            typeof(_state.currText) _text;
        }

        return Range(_state.currText);
    }


    /++
        Returns the value of the current entity.

        In the case of $(LREF EntityType.processingInstruction), this is the text
        that follows the name.

        $(TABLE
            $(TR $(TH Supported $(LREF EntityType)s:))
            $(TR $(TD $(LREF2 cdata, EntityType)))
            $(TR $(TD $(LREF2 comment, EntityType)))
            $(TR $(TD $(LREF2 processingInstruction, EntityType)))
            $(TR $(TD $(LREF2 _text, EntityType)))
        )
      +/
    @property SliceOfR text()
    {
        with(EntityType)
            assert(only(cdata, comment, processingInstruction, text).canFind(type));

        return stripBCU!R(_state.currText.input);
    }

    ///
    static if(compileInTests) unittest
    {
        enum xml = "<?xml version='1.0'?>\n" ~
                   "<?instructionName?>\n" ~
                   "<?foo here is something to say?>\n" ~
                   "<root>\n" ~
                   "    <![CDATA[ Yay! random text >> << ]]>\n" ~
                   "    <!-- some random comment -->\n" ~
                   "    <p>something here</p>\n" ~
                   "    <p>\n" ~
                   "       something else\n" ~
                   "       here</p>\n" ~
                   "</root>";
        {
            auto parser = parseXML(xml);

            // "<?xml version='1.0'?>\n" ~
            assert(parser.type == EntityType.xmlDecl);
            parser.next();

            // "<?instructionName?>\n" ~
            assert(parser.type == EntityType.processingInstruction);
            assert(parser.name == "instructionName");
            assert(parser.text.empty);
            parser.next();

            // "<?foo here is something to say?>\n" ~
            assert(parser.type == EntityType.processingInstruction);
            assert(parser.name == "foo");
            assert(parser.text == "here is something to say");
            parser.next();

            // "<root>\n" ~
            assert(parser.type == EntityType.elementStart);
            parser.next();

            // "    <![CDATA[ Yay! random text >> << ]]>\n" ~
            assert(parser.type == EntityType.cdata);
            assert(parser.text == " Yay! random text >> << ");
            parser.next();

            // "    <!-- some random comment -->\n" ~
            assert(parser.type == EntityType.comment);
            assert(parser.text == " some random comment ");
            parser.next();

            // "    <p>something here</p>\n" ~
            assert(parser.type == EntityType.elementStart);
            parser.next();
            assert(parser.type == EntityType.text);
            assert(parser.text == "something here");
            parser.next();
            assert(parser.type == EntityType.elementEnd);
            parser.next();

            // "    <p>\n" ~
            // "       something else\n" ~
            // "       here</p>\n" ~
            assert(parser.type == EntityType.elementStart);
            parser.next();
            assert(parser.type == EntityType.text);
            assert(parser.text == "\n       something else\n       here");
            parser.next();
            assert(parser.type == EntityType.elementEnd);
            parser.next();

            // "</root>"
            assert(parser.type == EntityType.elementEnd);
            parser.next();
            assert(parser.empty);
        }
        {
            auto parser = parseXML!(makeConfig(SkipContentWS.no))(xml);

            // "<?xml version='1.0'?>\n" ~
            assert(parser.type == EntityType.xmlDecl);
            parser.next();

            // "<?instructionName?>\n" ~
            assert(parser.type == EntityType.processingInstruction);
            assert(parser.name == "instructionName");
            assert(parser.text.empty);
            parser.next();

            // "<?foo here is something to say?>\n" ~
            assert(parser.type == EntityType.processingInstruction);
            assert(parser.name == "foo");
            assert(parser.text == "here is something to say");
            parser.next();

            // "<root>\n" ~
            assert(parser.type == EntityType.elementStart);
            parser.next();

            // With SkipContentWS.no, no EntityType.text entities are skipped,
            // even if they only contain whitespace, resulting in a number of
            // entities of type EntityType.text which just contain whitespace
            // if the XML has been formatted to be human readable.
            assert(parser.type == EntityType.text);
            assert(parser.text == "\n    ");
            parser.next();

            // "    <![CDATA[ Yay! random text >> << ]]>\n" ~
            assert(parser.type == EntityType.cdata);
            assert(parser.text == " Yay! random text >> << ");
            parser.next();
            assert(parser.type == EntityType.text);
            assert(parser.text == "\n    ");
            parser.next();

            // "    <!-- some random comment -->\n" ~
            assert(parser.type == EntityType.comment);
            assert(parser.text == " some random comment ");
            parser.next();
            assert(parser.type == EntityType.text);
            assert(parser.text == "\n    ");
            parser.next();

            // "    <p>something here</p>\n" ~
            assert(parser.type == EntityType.elementStart);
            parser.next();
            assert(parser.type == EntityType.text);
            assert(parser.text == "something here");
            parser.next();
            assert(parser.type == EntityType.elementEnd);
            parser.next();
            assert(parser.type == EntityType.text);
            assert(parser.text == "\n    ");
            parser.next();

            // "    <p>\n" ~
            // "       something else\n" ~
            // "       here</p>\n" ~
            assert(parser.type == EntityType.elementStart);
            parser.next();
            assert(parser.type == EntityType.text);
            assert(parser.text == "\n       something else\n       here");
            parser.next();
            assert(parser.type == EntityType.elementEnd);
            parser.next();
            assert(parser.type == EntityType.text);
            assert(parser.text == "\n");
            parser.next();

            // "</root>"
            assert(parser.type == EntityType.elementEnd);
            parser.next();
            assert(parser.empty);
        }
    }


    /++
        When at a start tag, moves the parser to the entity after the
        corresponding end tag tag and returns the contents between the two tags
        as text, leaving any markup in between as unprocessed text.

        $(TABLE
            $(TR $(TH Supported $(LREF EntityType)s:))
            $(TR $(TD $(LREF2 elementStart, EntityType)))
        )
      +/
    @property SliceOfR contentAsText()
    {
        assert(type == EntityType.elementStart);

        assert(0);
    }


    /++
        When at a start tag, moves the parser to the entity after the
        corresponding end tag.

        $(TABLE
            $(TR $(TH Supported $(LREF EntityType)s:))
            $(TR $(TD $(LREF2 elementStart, EntityType)))
        )
      +/
    void skipContents()
    {
        assert(type == EntityType.elementStart);

        assert(0);
    }


    /++
        Returns the $(LREF XMLDecl) corresponding to the current entity.

        $(TABLE
            $(TR $(TH Supported $(LREF EntityType)s:)),
            $(TR $(TD $(LREF2 _xmlDecl, EntityType)))
        )
      +/
    @property XMLDecl!R xmlDecl()
    {
        assert(type == EntityType.xmlDecl);

        import std.ascii : isDigit;

        void throwXPE(string msg, size_t line = __LINE__)
        {
            throw new XMLParsingException(msg, _state.currText.pos, __FILE__, line);
        }

        // We shouldn't need to use .init like this, but when compiling the
        // examples with filter, we get an error about accessing the frame
        // pointer if we don't, which seems like a bug in dmd which should
        // probably be reduced and reported.
        XMLDecl!R retval = XMLDecl!R.init;

        // XMLDecl      ::= '<?xml' VersionInfo EncodingDecl? SDDecl? S? '?>'
        // VersionInfo  ::= S 'version' Eq ("'" VersionNum "'" | '"' VersionNum '"')
        // Eq           ::= S? '=' S?
        // VersionNum   ::= '1.' [0-9]+
        // EncodingDecl ::= S 'encoding' Eq ('"' EncName '"' | "'" EncName "'" )
        // EncName      ::= [A-Za-z] ([A-Za-z0-9._] | '-')*
        // SDDecl       ::= S 'standalone' Eq (("'" ('yes' | 'no') "'") | ('"' ('yes' | 'no') '"'))

        // The '<?xml' and '?>' were already stripped off before _state.currText
        // was set.

        if(!stripWS(&_state.currText))
            throwXPE("There must be whitespace after <?xml");

        if(!stripStartsWith(&_state.currText, "version"))
            throwXPE("version missing after <?xml");
        stripEq(&_state.currText);

        {
            auto temp = takeEnquotedText(&_state.currText);
            retval.xmlVersion = stripBCU!R(temp.save);
            if(temp.length != 3)
                throwXPE("Invalid or unsupported XML version number");
            if(temp.front != '1')
                throwXPE("Invalid or unsupported XML version number");
            temp.popFront();
            if(temp.front != '.')
                throwXPE("Invalid or unsupported XML version number");
            temp.popFront();
            if(!isDigit(temp.front))
                throwXPE("Invalid or unsupported XML version number");
        }

        auto wasSpace = stripWS(&_state.currText);
        if(_state.currText.input.empty)
            return retval;

        if(_state.currText.input.front == 'e')
        {
            if(!wasSpace)
                throwXPE("There must be whitespace before the encoding declaration");
            popFrontAndIncCol(&_state.currText);
            if(!stripStartsWith(&_state.currText, "ncoding"))
                throwXPE("Invalid <?xml ... ?> declaration in prolog");
            stripEq(&_state.currText);
            retval.encoding = nullable(stripBCU!R(takeEnquotedText(&_state.currText)));

            wasSpace = stripWS(&_state.currText);
            if(_state.currText.input.empty)
                return retval;
        }

        if(_state.currText.input.front == 's')
        {
            if(!wasSpace)
                throwXPE("There must be whitespace before the standalone declaration");
            popFrontAndIncCol(&_state.currText);
            if(!stripStartsWith(&_state.currText, "tandalone"))
                throwXPE("Invalid <?xml ... ?> declaration in prolog");
            stripEq(&_state.currText);

            auto pos = _state.currText.pos;
            auto standalone = takeEnquotedText(&_state.currText);
            if(standalone.save.equalCU("yes"))
                retval.standalone = nullable(true);
            else if(standalone.equalCU("no"))
                retval.standalone = nullable(false);
            else
                throw new XMLParsingException("If standalone is present, its value must be yes or no", pos);
            stripWS(&_state.currText);
        }

        if(!_state.currText.input.empty)
            throwXPE("Invalid <?xml ... ?> declaration in prolog");

        return retval;
    }

    static if(compileInTests) unittest
    {
        import std.array : replace;
        import std.exception : assertThrown;
        import std.meta : AliasSeq;
        import std.range : only;

        foreach(func; testRangeFuncs)
        {
            {
                foreach(i; 0 .. 4)
                {
                    auto xml = "<?xml version='1.0'?><root/>";
                    if(i > 1)
                        xml = xml.replace(`'`, `"`);
                    if(i % 2 == 1)
                        xml = xml.replace("1.0", "1.1");
                    auto parser = parseXML(func(xml));
                    auto xmlDecl = parser.xmlDecl;
                    assert(equalCU(xmlDecl.xmlVersion, i % 2 == 0 ? "1.0" : "1.1"));
                    assert(xmlDecl.encoding.isNull);
                    assert(xmlDecl.standalone.isNull);
                }
            }
            {
                foreach(i; 0 .. 4)
                {
                    auto xml = "<?xml version='1.0' encoding='UTF-8'?><root/>";
                    if(i > 1)
                        xml = xml.replace(`'`, `"`);
                    if(i % 2 == 1)
                        xml = xml.replace("1.0", "1.1");
                    auto parser = parseXML(func(xml));
                    auto xmlDecl = parser.xmlDecl;
                    assert(equalCU(xmlDecl.xmlVersion, i % 2 == 0 ? "1.0" : "1.1"));
                    assert(equalCU(xmlDecl.encoding.get, "UTF-8"));
                    assert(xmlDecl.standalone.isNull);
                }
            }
            {
                foreach(i; 0 .. 8)
                {
                    auto xml = "<?xml version='1.0' encoding='UTF-8' standalone='yes'?><root/>";
                    if(i > 3)
                        xml = xml.replace(`'`, `"`).replace("yes", "no");
                    if(i % 2 == 1)
                        xml = xml.replace("1.0", "1.1");
                    auto parser = parseXML(func(xml));
                    auto xmlDecl = parser.xmlDecl;
                    assert(equalCU(xmlDecl.xmlVersion, i % 2 == 0 ? "1.0" : "1.1"));
                    assert(equalCU(xmlDecl.encoding.get, "UTF-8"));
                    assert(xmlDecl.standalone == (i < 4));
                }
            }
            {
                foreach(i; 0 .. 8)
                {
                    auto xml = "<?xml version='1.0' standalone='yes'?><root/>";
                    if(i > 3)
                        xml = xml.replace(`'`, `"`).replace("yes", "no");
                    if(i % 2 == 1)
                        xml = xml.replace("1.0", "1.1");
                    auto parser = parseXML(func(xml));
                    auto xmlDecl = parser.xmlDecl;
                    assert(equalCU(xmlDecl.xmlVersion, i % 2 == 0 ? "1.0" : "1.1"));
                    assert(xmlDecl.encoding.isNull);
                    assert(xmlDecl.standalone == (i < 4));
                }
            }

            assertThrown(parseXML(func("<?xml version='1.0'><root/>")));
            assertThrown(parseXML(func("<?xml version='1.0'><?root/>")));
            assertThrown(parseXML(func("<?xml version='1.0'? ><root/>")));
            assertThrown(parseXML(func("< ?xml version='1.0'?><root/>")));

            foreach(xml; only("<?xml version='1.a'?><root/>",
                              "<?xml version='0.0'?><root/>",
                              "<?xml version='2.0'?><root/>",
                              "<?xml version='10'?><root/>",
                              "<?xml version='100'?><root/>",
                              "<?xml version='1,0'?><root/>",
                              "<?xml versio='1.0'?><root/>",
                              "<?xml version='1.0 '?><root/>",
                              "<?xml?><root/>",
                              "<?xml version='1.0'encoding='UTF-8'?><root/>",
                              "<?xml version='1.0' encoding='UTF-8'standalone='yes'?><root/>",
                              "<?xml version='1.0'standalone='yes'?><root/>",
                              "<?xml version='1.0'\vencoding='UTF-8'?><root/>",
                              "<?xml version='1.0' encoding='UTF-8'\vstandalone='yes'?><root/>",
                              "<?xml version='1.0'\vstandalone='yes'?><root/>",
                              "<?xml version='1.0' standalone='yes' encoding='UTF-8'?><root/>",
                              "<?xml version='1.0' standalone='YES'?><root/>",
                              "<?xml version='1.0' standalone='NO'?><root/>",
                              "<?xml version='1.0' standalone='y'?><root/>",
                              "<?xml version='1.0' standalone='n'?><root/>",
                              "<?xml version='1.0  standalone='yes'?><root/>",
                              "<?xml version='1.0  standalone='yes''?><root/>",
                              "<?xml version='1.0' ecoding='UTF-8'?><root/>",
                              "<?xml version='1.0' silly='yes'?><root/>"))
            {
                auto parser = parseXML(func(xml));
                assertThrown!XMLParsingException(parser.xmlDecl);
            }
        }
    }


private:

    // Parse at GrammarPos.prologMisc1 or GrammarPos.prologMisc2.
    void _parseAtPrologMisc(int miscNum)()
    {
        static assert(miscNum == 1 || miscNum == 2);

        // document ::= prolog element Misc*
        // prolog   ::= XMLDecl? Misc* (doctypedecl Misc*)?
        // Misc ::= Comment | PI | S

        stripWS(_state);
        checkNotEmpty(_state);
        if(_state.input.front != '<')
            throw new XMLParsingException("Expected <", _state.pos);
        popFrontAndIncCol(_state);
        checkNotEmpty(_state);

        switch(_state.input.front)
        {
            // Comment     ::= '<!--' ((Char - '-') | ('-' (Char - '-')))* '-->'
            // doctypedecl ::= '<!DOCTYPE' S Name (S ExternalID)? S? ('[' intSubset ']' S?)? '>'
            case '!':
            {
                popFrontAndIncCol(_state);
                if(_state.stripStartsWith("--"))
                {
                    _parseComment!(config.skipProlog == SkipProlog.yes || config.skipComments == SkipComments.yes)();
                    break;
                }
                static if(miscNum == 1)
                {
                    if(_state.stripStartsWith("DOCTYPE"))
                    {
                        _parseDoctypeDecl();
                        break;
                    }
                }
                throw new XMLParsingException("Invalid XML", _state.pos);
            }
            // PI ::= '<?' PITarget (S (Char* - (Char* '?>' Char*)))? '?>'
            case '?':
            {
                _parsePI!(config.skipProlog == SkipProlog.yes || config.skipPI == SkipPI.yes);
                break;
            }
            // element ::= EmptyElemTag | STag content ETag
            default:
            {
                _parseElementStart();
                break;
            }
        }
    }


    // Comment ::= '<!--' ((Char - '-') | ('-' (Char - '-')))* '-->'
    // Parses a comment. <!-- was already removed from the front of the input.
    void _parseComment(bool skip = config.skipComments == SkipComments.yes)()
    {
        static if(skip)
            _state.skipUntilAndDrop!"--"();
        else
        {
            _state.type = EntityType.comment;
            _state.currText.pos = _state.pos;
            _state.currText.input = _state.takeUntilAndDrop!"--"();
        }
        if(_state.input.empty || _state.input.front != '>')
            throw new XMLParsingException("Comments cannot contain -- and cannot be terminated by --->", _state.pos);
        popFrontAndIncCol(_state);
    }


    // PI       ::= '<?' PITarget (S (Char* - (Char* '?>' Char*)))? '?>'
    // PITarget ::= Name - (('X' | 'x') ('M' | 'm') ('L' | 'l'))
    // Parses a processing instruction. < was already removed from the input.
    void _parsePI(bool skip = config.skipPI == SkipPI.yes)()
    {
        assert(_state.input.front == '?');
        popFrontAndIncCol(_state);
        static if(skip)
            _state.skipUntilAndDrop!"?>"();
        else
        {
            auto pos = _state.pos;
            _state.type = EntityType.processingInstruction;
            _state.currText.pos = _state.pos;
            _state.currText.input = _state.takeUntilAndDrop!"?>"();
            _state.name = takeName(&_state.currText);
            stripWS(&_state.currText);
            if(walkLength(_state.name.save) == 3)
            {
                // FIXME icmp doesn't compile right now due to an issue with
                // byUTF that needs to be looked into.
                /+
                import std.uni : icmp;
                if(icmp(_state.name.save, "xml") == 0)
                    throw new XMLParsingException("Processing instructions cannot be named xml", pos);
                +/
                if(_state.name.front == 'x' || _state.name.front == 'X')
                {
                    _state.name.popFront();
                    if(_state.name.front == 'm' || _state.name.front == 'M')
                    {
                        _state.name.popFront();
                        if(_state.name.front == 'l' || _state.name.front == 'L')
                            throw new XMLParsingException("Processing instructions cannot be named xml", pos);
                    }
                }
            }
            stripWS(_state);
        }
    }


    // CDSect  ::= CDStart CData CDEnd
    // CDStart ::= '<![CDATA['
    // CData   ::= (Char* - (Char* ']]>' Char*))
    // CDEnd   ::= ']]>'
    // Parses a CDATA. <!CDATA[ was already removed from the front of the input.
    void _parseCDATA()
    {
        _state.type = EntityType.cdata;
        _state.currText.pos = _state.pos;
        _state.currText.input = _state.takeUntilAndDrop!"]]>";
        _state.grammarPos = GrammarPos.contentCharData2;
    }


    // Parse doctypedecl after GrammarPos.prologMisc1.
    // <!DOCTYPE was already removed from the front of the input.
    void _parseDoctypeDecl()
    {
        if(!_state.stripWS())
            throw new XMLParsingException("Whitespace must follow <!DOCTYPE", _state.pos);
        static if(config.skipProlog == SkipProlog.yes)
        {
            _state.skipToOneOf!('[', '>')();
            checkNotEmpty(_state);
            if(_state.input.front == '[')
            {
                _state.skipUntilAndDrop!"]"();
                _state.skipUntilAndDrop!">"();
            }
            else
                popFrontAndIncCol(_state);
            _parseAtPrologMisc!2();
        }
        else
        {
            assert(0);
            //...
            //_state.grammarPos = GrammarPos.prologMisc2;
        }
    }


    // Parse a start tag or empty element tag. It could be the root element, or
    // it could be a sub-element.
    // < was already removed from the front of the input.
    void _parseElementStart()
    {
        _state.currText.pos = _state.pos;
        _state.currText.input = _state.takeUntilAndDrop!">"();
        auto temp = _state.currText.input.save;
        temp.popFrontN(temp.length - 1);
        if(temp.front == '/')
        {
            _state.currText.input = _state.currText.input.takeExactly(_state.currText.input.length - 1);

            static if(config.splitEmpty == SplitEmpty.no)
            {
                _state.type = EntityType.elementEmpty;
                _state.grammarPos = _state.tagStack.empty ? GrammarPos.endMisc : GrammarPos.contentCharData2;
            }
            else
            {
                _state.type = EntityType.elementStart;
                _state.grammarPos = GrammarPos.splittingEmpty;
            }
        }
        else
        {
            _state.type = EntityType.elementStart;
            _state.grammarPos = GrammarPos.contentCharData1;
        }

        if(_state.currText.input.empty)
            throw new XMLParsingException("Tag missing name", _state.currText.pos);
        _state.name = takeName(&_state.currText);
        stripWS(&_state.currText);
        // The attributes should be all that's left in currText.
    }


    // Parse an end tag. It could be the root element, or it could be a
    // sub-element.
    // </ was already removed from the front of the input.
    void _parseElementEnd()
    {
        import std.format : format;
        _state.type = EntityType.elementEnd;
        _state.currText.pos = _state.pos;
        _state.name = _state.takeUntilAndDrop!">"();
        assert(!_state.tagStack.empty);
        if(!equal(_state.name.save, _state.tagStack.back.save))
        {
            enum fmt = "Name of end tag </%s> does not match corresponding start tag <%s>";
            throw new XMLParsingException(format!fmt(_state.name, _state.tagStack.back), _state.currText.pos);
        }
        _state.tagStack.pop();
        _state.grammarPos = _state.tagStack.empty ? GrammarPos.endMisc : GrammarPos.contentCharData2;
    }


    // GrammarPos.contentCharData1
    // content ::= CharData? ((element | Reference | CDSect | PI | Comment) CharData?)*
    // Parses at either CharData?. Nothing from the CharData? (or what's after it
    // if it's not there) has been consumed.
    void _parseAtContentCharData()
    {
        checkNotEmpty(_state);
        static if(config.skipContentWS == SkipContentWS.yes)
        {
            auto origInput = _state.input.save;
            auto origPos = _state.pos;
            stripWS(_state);
            checkNotEmpty(_state);
            if(_state.input.front != '<')
            {
                _state.input = origInput;
                _state.pos = origPos;
            }
        }
        if(_state.input.front != '<')
        {
            _state.type = EntityType.text;
            _state.currText.pos = _state.pos;
            _state.currText.input = _state.takeUntilAndDrop!"<"();
            checkNotEmpty(_state);
            if(_state.input.front == '/')
            {
                popFrontAndIncCol(_state);
                _state.grammarPos = GrammarPos.endTag;
            }
            else
                _state.grammarPos = GrammarPos.contentMid;
        }
        else
        {
            popFrontAndIncCol(_state);
            checkNotEmpty(_state);
            if(_state.input.front == '/')
            {
                popFrontAndIncCol(_state);
                _parseElementEnd();
            }
            else
                _parseAtContentMid();
        }
    }


    // GrammarPos.contentMid
    // content     ::= CharData? ((element | Reference | CDSect | PI | Comment) CharData?)*
    // The text right after the start tag was what was parsed previously. So,
    // that first CharData? was what was parsed last, and this parses starting
    // right after. The < should have already been removed from the input.
    void _parseAtContentMid()
    {
        // Note that References are treated as part of the CharData and not
        // parsed out by the EntityParser (see EntityParser.text).

        switch(_state.input.front)
        {
            // Comment ::= '<!--' ((Char - '-') | ('-' (Char - '-')))* '-->'
            // CDSect  ::= CDStart CData CDEnd
            // CDStart ::= '<![CDATA['
            // CData   ::= (Char* - (Char* ']]>' Char*))
            // CDEnd   ::= ']]>'
            case '!':
            {
                popFrontAndIncCol(_state);
                if(_state.stripStartsWith("--"))
                {
                    _parseComment();
                    static if(config.skipComments == SkipComments.yes)
                        _parseAtContentCharData();
                    else
                        _state.grammarPos = GrammarPos.contentCharData2;
                }
                else if(_state.stripStartsWith("[CDATA["))
                    _parseCDATA();
                else
                    throw new XMLParsingException("Not valid Comment or CData section", _state.pos);
                break;
            }
            // PI ::= '<?' PITarget (S (Char* - (Char* '?>' Char*)))? '?>'
            case '?':
            {
                _parsePI();
                _state.grammarPos = GrammarPos.contentCharData2;
                break;
            }
            // element ::= EmptyElemTag | STag content ETag
            default:
            {
                _parseElementStart();
                break;
            }
        }
    }


    // This parses the Misc* that come after the root element.
    void _parseAtEndMisc()
    {
        // Misc ::= Comment | PI | S

        stripWS(_state);

        if(_state.input.empty)
        {
            _state.grammarPos = GrammarPos.documentEnd;
            return;
        }

        if(_state.input.front != '<')
            throw new XMLParsingException("Expected <", _state.pos);
        popFrontAndIncCol(_state);
        checkNotEmpty(_state);

        switch(_state.input.front)
        {
            // Comment ::= '<!--' ((Char - '-') | ('-' (Char - '-')))* '-->'
            case '!':
            {
                popFrontAndIncCol(_state);
                if(_state.stripStartsWith("--"))
                {
                    _parseComment();
                    break;
                }
                throw new XMLParsingException("Invalid XML", _state.pos);
            }
            // PI ::= '<?' PITarget (S (Char* - (Char* '?>' Char*)))? '?>'
            case '?':
            {
                _parsePI();
                break;
            }
            default: throw new XMLParsingException("Must be a comment or PI", _state.pos);
        }
    }


    this(R xmlText)
    {
        _state = new ParserState!(config, R)(xmlText);

        if(_state.stripStartsWith("<?xml"))
        {
            static if(config.skipProlog == SkipProlog.yes)
            {
                _state.skipUntilAndDrop!"?>"();
                _state.grammarPos = GrammarPos.prologMisc1;
                next();
            }
            else
            {
                _state.currText.pos = _state.pos;
                _state.currText.input = _state.takeUntilAndDrop!"?>"();
                _state.type = EntityType.xmlDecl;
                _state.grammarPos = GrammarPos.prologMisc1;
            }
        }
        else
            _parseAtPrologMisc!1();
    }

    static if(compileInTests) unittest
    {
        import std.meta : AliasSeq;
        import std.range : only;
        import std.typecons : tuple;

        foreach(func; testRangeFuncs)
        {
            {
                auto xml = "<root/>";

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 8)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    assert(parseXML!(t[0])(func(xml))._state.pos == t[1]);
                }
            }
            {
                auto xml = "\n\t\n <root/>   \n";

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(3, 9)),
                                     tuple(makeConfig(PositionType.line), SourcePos(3, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    assert(parseXML!(t[0])(func(xml))._state.pos == t[1]);
                }
            }
            {
                auto xml = "<?xml\n\n\nversion='1.8'\n\n\n\nencoding='UTF-8'\n\n\nstandalone='yes'\n?><root/>";

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(12, 3)),
                                     tuple(makeConfig(PositionType.line), SourcePos(12, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    assert(parseXML!(t[0])(func(xml))._state.pos == t[1]);
                }
            }
            {
                auto xml = "<?xml\n\n\n    \r\r\r\n\nversion='1.8'?><root/>";

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(6, 16)),
                                     tuple(makeConfig(PositionType.line), SourcePos(6, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    assert(parseXML!(t[0])(func(xml))._state.pos == t[1]);
                }
            }
            {
                auto xml = "<?xml\n\n\n    \r\r\r\n\nversion='1.8'?>\n     <root/>";

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(6, 16)),
                                     tuple(makeConfig(PositionType.line), SourcePos(6, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    assert(parseXML!(t[0])(func(xml))._state.pos == t[1]);
                }
            }

            {
                auto xml = "<root/>";

                foreach(t; AliasSeq!(tuple(makeConfig(SkipProlog.yes), SourcePos(1, 8)),
                                     tuple(makeConfig(SkipProlog.yes, PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(SkipProlog.yes, PositionType.none), SourcePos(-1, -1))))
                {
                    assert(parseXML!(t[0])(func(xml))._state.pos == t[1]);
                }
            }
            {
                auto xml = "\n\t\n <root/>   \n";

                foreach(t; AliasSeq!(tuple(makeConfig(SkipProlog.yes), SourcePos(3, 9)),
                                     tuple(makeConfig(SkipProlog.yes, PositionType.line), SourcePos(3, -1)),
                                     tuple(makeConfig(SkipProlog.yes, PositionType.none), SourcePos(-1, -1))))
                {
                    assert(parseXML!(t[0])(func(xml))._state.pos == t[1]);
                }
            }
            {
                auto xml = "<?xml\n\n\nversion='1.8'\n\n\n\nencoding='UTF-8'\n\n\nstandalone='yes'\n?><root/>";

                foreach(t; AliasSeq!(tuple(makeConfig(SkipProlog.yes), SourcePos(12, 10)),
                                     tuple(makeConfig(SkipProlog.yes, PositionType.line), SourcePos(12, -1)),
                                     tuple(makeConfig(SkipProlog.yes, PositionType.none), SourcePos(-1, -1))))
                {
                    assert(parseXML!(t[0])(func(xml))._state.pos == t[1]);
                }
            }
            {
                auto xml = "<?xml\n\n\n    \r\r\r\n\nversion='1.8'?><root/>";

                foreach(t; AliasSeq!(tuple(makeConfig(SkipProlog.yes), SourcePos(6, 23)),
                                     tuple(makeConfig(SkipProlog.yes, PositionType.line), SourcePos(6, -1)),
                                     tuple(makeConfig(SkipProlog.yes, PositionType.none), SourcePos(-1, -1))))
                {
                    assert(parseXML!(t[0])(func(xml))._state.pos == t[1]);
                }
            }
            {
                auto xml = "<?xml\n\n\n    \r\r\r\n\nversion='1.8'?>\n     <root/>";

                foreach(t; AliasSeq!(tuple(makeConfig(SkipProlog.yes), SourcePos(7, 13)),
                                     tuple(makeConfig(SkipProlog.yes, PositionType.line), SourcePos(7, -1)),
                                     tuple(makeConfig(SkipProlog.yes, PositionType.none), SourcePos(-1, -1))))
                {
                    assert(parseXML!(t[0])(func(xml))._state.pos == t[1]);
                }
            }
        }
    }

    ParserState!(config, R)* _state;
}

/// Ditto
EntityParser!(config, R) parseXML(Config config = Config.init, R)(R xmlText)
    if(isForwardRange!R && isSomeChar!(ElementType!R))
{
    return EntityParser!(config, R)(xmlText);
}

///
unittest
{
    enum xml = "<?xml version='1.0'?>\n" ~
               "<foo attr='42'>\n" ~
               "    <bar/>\n" ~
               "    <!-- no comment -->\n" ~
               "    <baz hello='world'>\n" ~
               "    nothing to say.\n" ~
               "    nothing at all...\n" ~
               "    </baz>\n" ~
               "</foo>";

    {
        auto parser = parseXML(xml);
        assert(!parser.empty);
        assert(parser.type == EntityType.xmlDecl);

        auto xmlDecl = parser.xmlDecl;
        assert(xmlDecl.xmlVersion == "1.0");
        assert(xmlDecl.encoding.isNull);
        assert(xmlDecl.standalone.isNull);

        parser.next();
        assert(parser.type == EntityType.elementStart);
        assert(parser.name == "foo");

        {
            auto attrs = parser.attributes;
            assert(walkLength(attrs.save) == 1);
            assert(attrs.front.name == "attr");
            assert(attrs.front.value == "42");
        }

        parser.next();
        assert(parser.type == EntityType.elementEmpty);
        assert(parser.name == "bar");

        parser.next();
        assert(parser.type == EntityType.comment);
        assert(parser.text == " no comment ");

        parser.next();
        assert(parser.type == EntityType.elementStart);
        assert(parser.name == "baz");

        {
            auto attrs = parser.attributes;
            assert(walkLength(attrs.save) == 1);
            assert(attrs.front.name == "hello");
            assert(attrs.front.value == "world");
        }

        parser.next();
        assert(parser.type == EntityType.text);
        assert(parser.text ==
               "\n    nothing to say.\n    nothing at all...\n    ");

        parser.next();
        assert(parser.type == EntityType.elementEnd); // </baz>

        parser.next();
        assert(parser.type == EntityType.elementEnd); // </foo>

        parser.next();
        assert(parser.empty);
    }

    {
        auto parser = parseXML!simpleXML(xml);
        assert(!parser.empty);
        assert(parser.type == EntityType.elementStart);
        assert(parser.name == "foo");

        {
            auto attrs = parser.attributes;
            assert(walkLength(attrs.save) == 1);
            assert(attrs.front.name == "attr");
            assert(attrs.front.value == "42");
        }

        parser.next();
        // simpleXML is set to split empty tags so that <bar/> is treated
        // as the same as <bar></bar> so that code does not have to
        // explicitly handle empty tags.
        assert(parser.type == EntityType.elementStart);
        assert(parser.name == "bar");
        parser.next();
        assert(parser.type == EntityType.elementEnd);

        parser.next();
        assert(parser.type == EntityType.elementStart);
        assert(parser.name == "baz");

        {
            auto attrs = parser.attributes;
            assert(walkLength(attrs.save) == 1);
            assert(attrs.front.name == "hello");
            assert(attrs.front.value == "world");
        }

        parser.next();
        assert(parser.type == EntityType.text);
        assert(parser.text ==
               "\n    nothing to say.\n    nothing at all...\n    ");

        parser.next();
        assert(parser.type == EntityType.elementEnd); // </baz>

        parser.next();
        assert(parser.type == EntityType.elementEnd); // </foo>

        parser.next();
        assert(parser.empty);
    }
}

// This is purely to provide a way to trigger the unittest blocks in Entity
// without compiling them in normally.
private struct EntityCompileTests
{
    @property bool empty() { assert(0); }
    @property char front() { assert(0); }
    void popFront() { assert(0); }
    @property typeof(this) save() { assert(0); }
}

version(unittest)
    EntityParser!(Config.init, EntityCompileTests) _entityParserTests;


/++
    Information parsed from a `<?xml ... ?>` declaration.

    Note that while XML 1.1 requires this declaration, it's optional in XML
    1.0.
  +/
struct XMLDecl(R)
{
    import std.typecons : Nullable;

    /++
        The type used when any slice of the original text is used. If $(D R)
        is a string or supports slicing, then SliceOfR is the same as $(D R);
        otherwise, it's the result of calling
        $(PHOBOS_REF takeExcatly, std, range) on the text.

        See_Also: $(LREF XMLParser._SliceOfR)
      +/
    static if(isDynamicArray!R || hasSlicing!R)
        alias SliceOfR = R;
    else
        alias SliceOfR = typeof(takeExactly(R.init, 42));

    /++
        The version of XML that the document contains.
      +/
    SliceOfR xmlVersion;

    /++
        The encoding of the text in the XML document.

        Note that dxml only supports UTF-8, UTF-16, and UTF-32, and it is
        assumed that the encoding matches the character type. The parser
        ignores this field aside from providing its value as part of an
        $(LREF XMLDecl).

        Anyone looking to make their program determine the encoding based on
        the $(D "encoding") field, should read
        $(LINK http://www.w3.org/TR/REC-xml/#sec-guessing).
      +/
    Nullable!SliceOfR encoding;

    /++
        $(D true) if the XML document does $(I not) contain any external
        references. $(D false) if it does or may contain external references.
        It's null if the $(D "standalone") declaration was not included in the
        `<?xml ..?>` declaration.
      +/
    Nullable!bool standalone;
}


//------------------------------------------------------------------------------
// Private Section
//------------------------------------------------------------------------------
private:


struct ParserState(Config cfg, R)
{
    alias config = cfg;
    alias Text = R;
    alias Taken = typeof(takeExactly(byCodeUnit(R.init), 42));

    EntityType type;

    GrammarPos grammarPos;

    static if(config.posType == PositionType.lineAndCol)
        auto pos = SourcePos(1, 1);
    else static if(config.posType == PositionType.line)
        auto pos = SourcePos(1, -1);
    else
        SourcePos pos;

    typeof(byCodeUnit(R.init)) input;

    // This mirrors the ParserState's fields so that the same parsing functions
    // can be used to parse main text contained directly in the ParserState
    // and the currently saved text (e.g. for the attributes of a start tag).
    struct CurrText
    {
        alias config = cfg;
        alias Text = R;
        Taken input;
        SourcePos pos;
    }

    CurrText currText;

    Taken name;
    TagStack!Taken tagStack;

    this(R xmlText)
    {
        input = byCodeUnit(xmlText);
        currText = typeof(currText).init; // This is utterly stupid. https://issues.dlang.org/show_bug.cgi?id=13945
        name = typeof(name).init; // This is utterly stupid. https://issues.dlang.org/show_bug.cgi?id=13945
    }
}


version(unittest) auto testParser(Config config, R)(R xmlText) @trusted pure nothrow @nogc
{
    static getPS(R xmlText) @trusted nothrow @nogc
    {
        static ParserState!(config, R) ps;
        ps = ParserState!(config, R)(xmlText);
        return &ps;
    }
    alias FuncType = @trusted pure nothrow @nogc ParserState!(config, R)* function(R);
    return (cast(FuncType)&getPS)(xmlText);
}


// Used to indicate where in the grammar we're currently parsing.
enum GrammarPos
{
    // document ::= prolog element Misc*
    // prolog   ::= XMLDecl? Misc* (doctypedecl Misc*)?
    // This is that first Misc*. The next entity to parse is either a Misc, the
    // doctypedecl, or the root element which follows the prolog.
    prologMisc1,

    // document ::= prolog element Misc*
    // prolog   ::= XMLDecl? Misc* (doctypedecl Misc*)
    // This is that second Misc*. The next entity to parse is either a Misc or
    // the root element which follows the prolog.
    prologMisc2,

    // doctypedecl ::= '<!DOCTYPE' S Name (S ExternalID)? S? ('[' intSubset ']' S?)? '>'
    // intSubset   ::= (markupdecl | DeclSep)*
    // This is the intSubset such that the next thing to parse is a markupdecl,
    // DeclSep, or the ']' that follows the intSubset.
    intSubset,

    /+
    // document ::= prolog element Misc*
    // element  ::= EmptyElemTag | STag content ETag
    // This at the element. The next thing to parse will either be an
    // EmptyElemTag or STag.
    element,
    +/

    // Used with SplitEmpty.yes to tell the parser that we're currently at an
    // empty element tag that we're treating as a start tag, so the next entity
    // will be an end tag even though we didn't actually parse one.
    splittingEmpty,

    // element  ::= EmptyElemTag | STag content ETag
    // content ::= CharData? ((element | Reference | CDSect | PI | Comment) CharData?)*
    // This is at the beginning of content at the first CharData?. The next
    // thing to parse will be a CharData, element, CDSect, PI, Comment, or ETag.
    // References are treated as part of the CharData and not parsed out by the
    // EntityParser (see EntityParser.text).
    contentCharData1,

    // element  ::= EmptyElemTag | STag content ETag
    // content ::= CharData? ((element | Reference | CDSect | PI | Comment) CharData?)*
    // This is after the first CharData?. The next thing to parse will be a
    // element, CDSect, PI, Comment, or ETag.
    // References are treated as part of the CharData and not parsed out by the
    // EntityParser (see EntityParser.text).
    contentMid,

    // element  ::= EmptyElemTag | STag content ETag
    // content ::= CharData? ((element | Reference | CDSect | PI | Comment) CharData?)*
    // This is at the second CharData?. The next thing to parse will be a
    // CharData, element, CDSect, PI, Comment, or ETag.
    // References are treated as part of the CharData and not parsed out by the
    // EntityParser (see EntityParser.text).
    contentCharData2,

    // element  ::= EmptyElemTag | STag content ETag
    // content ::= CharData? ((element | Reference | CDSect | PI | Comment) CharData?)*
    // This is after the second CharData?. The next thing to parse is an ETag.
    endTag,

    // document ::= prolog element Misc*
    // This is the Misc* at the end of the document. The next thing to parse is
    // either another Misc, or we will hit the end of the document.
    endMisc,

    // The end of the document (and the grammar) has been reached.
    documentEnd
}


// Similar to startsWith except that it consumes the part of the range that
// matches. It also deals with incrementing state.pos.col.
//
// It is assumed that there are no newlines.
bool stripStartsWith(PS)(PS state, string text)
{
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");

    alias R = typeof(PS.input);

    static if(hasLength!R)
    {
        if(state.input.length < text.length)
            return false;

        // This branch is separate so that we can take advantage of whatever
        // speed boost comes from comparing strings directly rather than
        // comparing individual characters.
        static if(isDynamicArray!(PS.Text) && is(Unqual!(ElementEncodingType!(PS.Text)) == char))
        {
            if(state.input.source[0 .. text.length] != text)
                return false;
            state.input.popFrontN(text.length);
        }
        else
        {
            auto origInput = state.input.save;
            auto origPos = state.pos;

            foreach(c; text)
            {
                if(state.input.front != c)
                {
                    state.input = origInput;
                    state.pos = origPos;
                    return false;
                }
                state.input.popFront();
            }
        }
    }
    else
    {
        auto origInput = state.input.save;
        auto origPos = state.pos;

        foreach(c; text)
        {
            if(state.input.empty)
            {
                state.input = origInput;
                state.pos = origPos;
                return false;
            }
            if(state.input.front != c)
            {
                state.input = origInput;
                state.pos = origPos;
                return false;
            }
            state.input.popFront();
        }
    }

    static if(state.config.posType == PositionType.lineAndCol)
        state.pos.col += text.length;

    return true;
}

@safe pure unittest
{
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    enum origHaystack = "hello world";
    enum needle = "hello";
    enum remainder = " world";

    foreach(func; testRangeFuncs)
    {
        auto haystack = func(origHaystack);

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, needle.length + 1)),
                             tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            auto state = testParser!(t[0])(haystack.save);
            assert(state.stripStartsWith(needle));
            assert(equalCU(state.input, remainder));
            assert(state.pos == t[1]);
        }

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, origHaystack.length + 1)),
                             tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            auto state = testParser!(t[0])(haystack.save);
            assert(state.stripStartsWith(origHaystack));
            assert(state.input.empty);
            assert(state.pos == t[1]);
        }

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 1)),
                             tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            {
                auto state = testParser!(t[0])(haystack.save);
                assert(!state.stripStartsWith("foo"));
                assert(equalCU(state.input, origHaystack));
                assert(state.pos == t[1]);
            }
            {
                auto state = testParser!(t[0])(haystack.save);
                assert(!state.stripStartsWith("hello sally"));
                assert(equalCU(state.input, origHaystack));
                assert(state.pos == t[1]);
            }
            {
                auto state = testParser!(t[0])(haystack.save);
                assert(!state.stripStartsWith("hello world "));
                assert(equalCU(state.input, origHaystack));
                assert(state.pos == t[1]);
            }
        }
    }
}


// Strips whitespace while dealing with state.pos accordingly. Newlines are not
// ignored.
// Returns whether any whitespace was stripped.
bool stripWS(PS)(PS state)
{
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");

    alias R = typeof(PS.input);
    enum hasLengthAndCol = hasLength!R && PS.config.posType == PositionType.lineAndCol;

    bool strippedSpace = false;

    static if(hasLengthAndCol)
        size_t lineStart = state.input.length;

    loop: while(!state.input.empty)
    {
        switch(state.input.front)
        {
            case ' ':
            case '\t':
            case '\r':
            {
                strippedSpace = true;
                state.input.popFront();
                static if(!hasLength!R)
                    nextCol!(PS.config)(state.pos);
                break;
            }
            case '\n':
            {
                strippedSpace = true;
                state.input.popFront();
                static if(hasLengthAndCol)
                    lineStart = state.input.length;
                nextLine!(PS.config)(state.pos);
                break;
            }
            default: break loop;
        }
    }

    static if(hasLengthAndCol)
        state.pos.col += lineStart - state.input.length;

    return strippedSpace;
}

@safe pure unittest
{
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    foreach(func; testRangeFuncs)
    {
        auto haystack1 = func("  \t\rhello world");

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 5)),
                             tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            auto state = testParser!(t[0])(haystack1.save);
            assert(state.stripWS());
            assert(equalCU(state.input, "hello world"));
            assert(state.pos == t[1]);
        }

        auto haystack2 = func("  \n \n \n  \nhello world");

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(5, 1)),
                             tuple(makeConfig(PositionType.line), SourcePos(5, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            auto state = testParser!(t[0])(haystack2.save);
            assert(state.stripWS());
            assert(equalCU(state.input, "hello world"));
            assert(state.pos == t[1]);
        }

        auto haystack3 = func("  \n \n \n  \n  hello world");

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(5, 3)),
                             tuple(makeConfig(PositionType.line), SourcePos(5, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            auto state = testParser!(t[0])(haystack3.save);
            assert(state.stripWS());
            assert(equalCU(state.input, "hello world"));
            assert(state.pos == t[1]);
        }

        auto haystack4 = func("hello world");

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 1)),
                             tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            auto state = testParser!(t[0])(haystack4.save);
            assert(!state.stripWS());
            assert(equal(state.input, "hello world"));
            assert(state.pos == t[1]);
        }
    }
}


// Returns a slice (or takeExactly) of state.input up to but not including the
// given text, removing both that slice and the given text from state.input in
// the process. If the text is not found, then an XMLParsingException is thrown.
auto takeUntilAndDrop(string text, PS)(PS state)
{
    return _takeUntilAndDrop!(true, text, PS)(state);
}

unittest
{
    import std.exception : assertThrown;
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    foreach(func; testRangeFuncs)
    {
        {
            auto haystack = func("hello world");
            enum needle = "world";

            static foreach(i; 1 .. needle.length)
            {
                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 7 + i)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(state.takeUntilAndDrop!(needle[0 .. i])(), "hello "));
                    assert(equal(state.input, needle[i .. $]));
                    assert(state.pos == t[1]);
                }
            }
        }
        {
            auto haystack = func("lello world");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 2)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                assert(state.takeUntilAndDrop!"l"().empty);
                assert(equal(state.input, "ello world"));
                assert(state.pos == t[1]);
            }

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 5)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                assert(equal(state.takeUntilAndDrop!"ll"(), "le"));
                assert(equal(state.input, "o world"));
                assert(state.pos == t[1]);
            }
        }
        {
            auto haystack = func("llello world");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 4)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                assert(equal(state.takeUntilAndDrop!"le"(), "l"));
                assert(equal(state.input, "llo world"));
                assert(state.pos == t[1]);
            }
        }
        {
            import std.utf : codeLength;
            auto haystack = func("プログラミング in D is great indeed");
            enum len = cast(int)codeLength!(ElementEncodingType!(typeof(haystack)))("プログラミング in D is ");
            enum needle = "great";
            enum remainder = "great indeed";

            static foreach(i; 1 .. needle.length)
            {
                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, len + i + 1)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(state.takeUntilAndDrop!(needle[0 .. i])(), "プログラミング in D is "));
                    assert(equal(state.input, remainder[i .. $]));
                    assert(state.pos == t[1]);
                }
            }
        }
        foreach(origHaystack; AliasSeq!("", "a", "hello"))
        {
            auto haystack = func(origHaystack);

            foreach(config; AliasSeq!(Config.init, makeConfig(PositionType.line), makeConfig(PositionType.none)))
            {
                auto state = testParser!config(haystack.save);
                assertThrown!XMLParsingException(state.takeUntilAndDrop!"x"());
            }
        }
        foreach(origHaystack; AliasSeq!("", "l", "lte", "world", "nomatch"))
        {
            auto haystack = func(origHaystack);

            foreach(config; AliasSeq!(Config.init, makeConfig(PositionType.line), makeConfig(PositionType.none)))
            {
                auto state = testParser!config(haystack.save);
                assertThrown!XMLParsingException(state.takeUntilAndDrop!"le"());
            }
        }
        foreach(origHaystack; AliasSeq!("", "w", "we", "wew", "bwe", "we b", "hello we go", "nomatch"))
        {
            auto haystack = func(origHaystack);

            foreach(config; AliasSeq!(Config.init, makeConfig(PositionType.line), makeConfig(PositionType.none)))
            {
                auto state = testParser!config(haystack.save);
                assertThrown!XMLParsingException(state.takeUntilAndDrop!"web"());
            }
        }
    }
}

// Variant of takeUntilAndDrop which does not return a slice. It's intended for
// when the config indicates that something should be skipped.
void skipUntilAndDrop(string text, PS)(PS state)
{
    return _takeUntilAndDrop!(false, text, PS)(state);
}

unittest
{
    import std.exception : assertThrown;
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    foreach(func; testRangeFuncs)
    {
        {
            auto haystack = func("hello world");
            enum needle = "world";

            static foreach(i; 1 .. needle.length)
            {
                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 7 + i)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    state.skipUntilAndDrop!(needle[0 .. i])();
                    assert(equal(state.input, needle[i .. $]));
                    assert(state.pos == t[1]);
                }
            }
        }
        {
            auto haystack = func("lello world");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 2)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                state.skipUntilAndDrop!"l"();
                assert(equal(state.input, "ello world"));
                assert(state.pos == t[1]);
            }

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 5)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                state.skipUntilAndDrop!"ll"();
                assert(equal(state.input, "o world"));
                assert(state.pos == t[1]);
            }
        }
        {
            auto haystack = func("llello world");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 4)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                state.skipUntilAndDrop!"le"();
                assert(equal(state.input, "llo world"));
                assert(state.pos == t[1]);
            }
        }
        {
            import std.utf : codeLength;
            auto haystack = func("プログラミング in D is great indeed");
            enum len = cast(int)codeLength!(ElementEncodingType!(typeof(haystack)))("プログラミング in D is ");
            enum needle = "great";
            enum remainder = "great indeed";

            static foreach(i; 1 .. needle.length)
            {
                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, len + i + 1)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    state.skipUntilAndDrop!(needle[0 .. i])();
                    assert(equal(state.input, remainder[i .. $]));
                    assert(state.pos == t[1]);
                }
            }
        }
        foreach(origHaystack; AliasSeq!("", "a", "hello"))
        {
            auto haystack = func(origHaystack);

            foreach(config; AliasSeq!(Config.init, makeConfig(PositionType.line), makeConfig(PositionType.none)))
            {
                auto state = testParser!config(haystack.save);
                assertThrown!XMLParsingException(state.skipUntilAndDrop!"x"());
            }
        }
        foreach(origHaystack; AliasSeq!("", "l", "lte", "world", "nomatch"))
        {
            auto haystack = func(origHaystack);

            foreach(config; AliasSeq!(Config.init, makeConfig(PositionType.line), makeConfig(PositionType.none)))
            {
                auto state = testParser!config(haystack.save);
                assertThrown!XMLParsingException(state.skipUntilAndDrop!"le"());
            }
        }
        foreach(origHaystack; AliasSeq!("", "w", "we", "wew", "bwe", "we b", "hello we go", "nomatch"))
        {
            auto haystack = func(origHaystack);

            foreach(config; AliasSeq!(Config.init, makeConfig(PositionType.line), makeConfig(PositionType.none)))
            {
                auto state = testParser!config(haystack.save);
                assertThrown!XMLParsingException(state.skipUntilAndDrop!"web"());
            }
        }
    }
}

auto _takeUntilAndDrop(bool retSlice, string text, PS)(PS state)
{
    import std.algorithm : find;
    import std.ascii : isWhite;

    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");
    static assert(text.find!isWhite().empty);

    enum trackTakeLen = retSlice || state.config.posType == PositionType.lineAndCol;

    alias R = typeof(PS.input);
    auto orig = state.input.save;
    bool found = false;

    static if(trackTakeLen)
        size_t takeLen = 0;

    static if(state.config.posType == PositionType.lineAndCol)
        size_t lineStart = 0;

    loop: while(!state.input.empty)
    {
        switch(state.input.front)
        {
            case cast(ElementType!R)text[0]:
            {
                static if(text.length == 1)
                {
                    found = true;
                    state.input.popFront();
                    break loop;
                }
                else static if(text.length == 2)
                {
                    state.input.popFront();
                    if(!state.input.empty && state.input.front == text[1])
                    {
                        found = true;
                        state.input.popFront();
                        break loop;
                    }
                    static if(trackTakeLen)
                        ++takeLen;
                    continue;
                }
                else
                {
                    state.input.popFront();
                    auto saved = state.input.save;
                    foreach(i, c; text[1 .. $])
                    {
                        if(state.input.empty)
                        {
                            static if(trackTakeLen)
                                takeLen += i + 1;
                            break loop;
                        }
                        if(state.input.front != c)
                        {
                            state.input = saved;
                            static if(trackTakeLen)
                                ++takeLen;
                            continue loop;
                        }
                        state.input.popFront();
                    }
                    found = true;
                    break loop;
                }
            }
            static if(state.config.posType != PositionType.none)
            {
                case '\n':
                {
                    static if(trackTakeLen)
                        ++takeLen;
                    nextLine!(state.config)(state.pos);
                    static if(state.config.posType == PositionType.lineAndCol)
                        lineStart = takeLen;
                    break;
                }
            }
            default:
            {
                static if(trackTakeLen)
                    ++takeLen;
                break;
            }
        }

        state.input.popFront();
    }

    static if(state.config.posType == PositionType.lineAndCol)
        state.pos.col += takeLen - lineStart + text.length;
    if(!found)
        throw new XMLParsingException("Failed to find: " ~ text, state.pos);
    static if(retSlice)
        return takeExactly(orig, takeLen);
}


// Okay, this name kind of sucks, because it's too close to skipUntilAndDrop,
// but I'd rather do this than be passing template arguments to choosed between
// behaviors - especially when the logic is so different. It skips until it
// reaches one of the two delimiter characters. If it finds one of them, then
// the first character in the input is the delimiter that was found, and if it
// doesn't find either, then the input is empty.
void skipToOneOf(char delim1, char delim2, PS)(PS state)
{
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");
    static assert(!isSpace(delim1) && !isSpace(delim2));

    while(!state.input.empty)
    {
        switch(state.input.front)
        {
            case delim1:
            case delim2: return;
            static if(state.config.posType != PositionType.none)
            {
                case '\n':
                {
                    nextLine!(state.config)(state.pos);
                    state.input.popFront();
                    break;
                }
            }
            default:
            {
                popFrontAndIncCol(state);
                break;
            }
        }

    }
}

unittest
{
    import std.exception : assertThrown;
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    foreach(func; testRangeFuncs)
    {
        {
            auto haystack = func("hello world");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 5)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                state.skipToOneOf!('o', 'w')();
                assert(equal(state.input, "o world"));
                assert(state.pos == t[1]);
            }

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 7)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                state.skipToOneOf!('r', 'w')();
                assert(equal(state.input, "world"));
                assert(state.pos == t[1]);
            }

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 12)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                state.skipToOneOf!('a', 'b')();
                assert(state.input.empty);
                assert(state.pos == t[1]);
            }
        }
        {
            auto haystack = func("abc\n\n\n  \n\n   wxyzzy \nf\ng");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(6, 6)),
                                 tuple(makeConfig(PositionType.line), SourcePos(6, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                state.skipToOneOf!('z', 'y')();
                assert(equal(state.input, "yzzy \nf\ng"));
                assert(state.pos == t[1]);
            }

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(8, 1)),
                                 tuple(makeConfig(PositionType.line), SourcePos(8, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                state.skipToOneOf!('o', 'g')();
                assert(equal(state.input, "g"));
                assert(state.pos == t[1]);
            }
        }
        {
            import std.utf : codeLength;
            auto haystack = func("プログラミング in D is great indeed");
            enum len = cast(int)codeLength!(ElementEncodingType!(typeof(haystack)))("プログラミング in D is ");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, len + 1)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                state.skipToOneOf!('g', 'x')();
                assert(equal(state.input, "great indeed"));
                assert(state.pos == t[1]);
            }
        }
    }
}


// The front of the input should be text surrounded by single or double quotes.
// This returns a slice of the input containing that text, and the input is
// advanced to one code unit beyond the quote.
auto takeEnquotedText(PS)(PS state)
{
    import std.meta : AliasSeq;
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");
    checkNotEmpty(state);
    immutable quote = state.input.front;
    foreach(quoteChar; AliasSeq!(`"`, `'`))
    {
        // This would be a bit simpler if takeUntilAndDrop took a runtime
        // argument, but in all other cases, a compile-time argument makes more
        // sense, so this seemed like a reasonable way to handle this one case.
        if(quote == quoteChar[0])
        {
            popFrontAndIncCol(state);
            return takeUntilAndDrop!quoteChar(state);
        }
    }
    throw new XMLParsingException("Expected quoted text", state.pos);
}

unittest
{
    import std.exception : assertThrown;
    import std.range : only;
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    foreach(func; testRangeFuncs)
    {
        foreach(quote; only("\"", "'"))
        {
            {
                auto haystack = func(quote ~ quote);

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 3)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(takeEnquotedText(state).empty);
                    assert(state.input.empty);
                    assert(state.pos == t[1]);
                }
            }
            {
                auto haystack = func(quote ~ "hello world" ~ quote);

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 14)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(takeEnquotedText(state), "hello world"));
                    assert(state.input.empty);
                    assert(state.pos == t[1]);
                }
            }
            {
                auto haystack = func(quote ~ "hello world" ~ quote ~ " foo");

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 14)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(takeEnquotedText(state), "hello world"));
                    assert(equal(state.input, " foo"));
                    assert(state.pos == t[1]);
                }
            }
            {
                import std.utf : codeLength;
                auto haystack = func(quote ~ "プログラミング " ~ quote ~ "in D");
                enum len = cast(int)codeLength!(ElementEncodingType!(typeof(haystack)))("プログラミング ");

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, len + 3)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(takeEnquotedText(state), "プログラミング "));
                    assert(equal(state.input, "in D"));
                    assert(state.pos == t[1]);
                }
            }
        }

        foreach(str; only(`hello`, `"hello'`, `"hello`, `'hello"`, `'hello`, ``, `"'`, `"`, `'"`, `'`))
            assertThrown!XMLParsingException(testParser!(Config.init)(func(str)).takeEnquotedText());
    }
}


// Parses
// Eq ::= S? '=' S?
void stripEq(PS)(PS state)
{
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");
    stripWS(state);
    if(!stripStartsWith(state, "="))
        throw new XMLParsingException("= missing", state.pos);
    stripWS(state);
}

unittest
{
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    foreach(func; testRangeFuncs)
    {
        {
            auto haystack = func("=");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 2)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                stripEq(state);
                assert(state.input.empty);
                assert(state.pos == t[1]);
            }
        }
        {
            auto haystack = func("=hello");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 2)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                stripEq(state);
                assert(equal(state.input, "hello"));
                assert(state.pos == t[1]);
            }
        }
        {
            auto haystack = func(" \n\n =hello");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(3, 3)),
                                 tuple(makeConfig(PositionType.line), SourcePos(3, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                stripEq(state);
                assert(equal(state.input, "hello"));
                assert(state.pos == t[1]);
            }
        }
        {
            auto haystack = func("=\n\n\nhello");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(4, 1)),
                                 tuple(makeConfig(PositionType.line), SourcePos(4, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                stripEq(state);
                assert(equal(state.input, "hello"));
                assert(state.pos == t[1]);
            }
        }
    }
}


// Removes a name (per the Name grammar rule) from the front of the input and
// returns it.
// If delim is char.init, then XML space is the delimeter, otherwise it's
// whatever delim is, but all the XML space between the name and the delimiter
// is stripped. The delimiter is also stripped.
auto takeName(char delim = char.init, PS)(PS state)
{

    import std.format : format;
    enum hasDelim = delim != char.init;

    assert(!state.input.empty);

    static if(hasDelim)
    {
        if(state.input.front == delim)
            throw new XMLParsingException("Cannot have empty name", state.pos);
    }

    auto orig = state.input.save;
    size_t takeLen;
    auto c = state.input.decodeFront!(UseReplacementDchar.yes)(takeLen);
    if(!isNameStartChar(c))
        throw new XMLParsingException(format!"Name contains invalid character: %s"(c), state.pos);

    if(state.input.empty)
    {
        static if(hasDelim)
            throw new XMLParsingException("Missing " ~ delim, state.pos);
    }
    else
    {
        while(true)
        {
            static if(hasDelim)
            {
                if(isSpace(state.input.front))
                {
                    static if(state.config.posType == PositionType.lineAndCol)
                        state.pos.col += takeLen;
                    stripWS(state);
                    if(state.input.empty)
                        throw new XMLParsingException("Missing " ~ delim, state.pos);
                    if(state.input.front != delim)
                    {
                        throw new XMLParsingException("Characters other than whitespace between name and " ~ delim,
                                                      state.pos);
                    }
                    popFrontAndIncCol(state);
                    break;
                }
                else if(state.input.front == delim)
                {
                    static if(state.config.posType == PositionType.lineAndCol)
                        state.pos.col += takeLen;
                    popFrontAndIncCol(state);
                    break;
                }
            }
            else
            {
                if(isSpace(state.input.front))
                    break;
            }

            size_t numCodeUnits;
            c = state.input.decodeFront!(UseReplacementDchar.yes)(numCodeUnits);
            if(!isNameChar(c))
                throw new XMLParsingException(format!"Name contains invalid character: %s"(c), state.pos);
            takeLen += numCodeUnits;

            if(state.input.empty)
            {
                static if(hasDelim)
                    throw new XMLParsingException("Missing " ~ delim, state.pos);
                else
                    break;
            }
        }
    }

    static if(!hasDelim && state.config.posType == PositionType.lineAndCol)
        state.pos.col += takeLen;

    return takeExactly(orig, takeLen);
}

unittest
{
    import std.exception : assertThrown;
    import std.meta : AliasSeq;
    import std.typecons : tuple;
    import std.utf : codeLength;

    foreach(func; testRangeFuncs)
    {
        foreach(str; AliasSeq!("hello", "プログラミング", "h_:llo-.42", "_.", "_-", "_42"))
        {
            enum len = cast(int)codeLength!(ElementEncodingType!(typeof(func("hello"))))(str);

            foreach(remainder; AliasSeq!("", " ", "\t", "\r", "\n", " foo", "\tfoo", "\rfoo", "\nfoo"))
            {
                auto haystack = func(str ~ remainder);

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, len + 1)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(takeName(state), str));
                    assert(equal(state.input, remainder));
                    assert(state.pos == t[1]);
                }
            }

            foreach(ends; AliasSeq!(tuple("=", ""), tuple(" =", ""), tuple("\t\r=  ", "  "),
                                    tuple("=foo", "foo"), tuple(" =foo", "foo"), tuple("\t\r=  bar", "  bar")))
            {
                auto haystack = func(str ~ ends[0]);

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, len + 1 + ends[0].length - ends[1].length)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(takeName!'='(state), str));
                    assert(equal(state.input, ends[1]));
                    assert(state.pos == t[1]);
                }
            }

            {
                auto ends = tuple("\n\n  \n \n \r\t  =blah", "blah");
                auto haystack = func(str ~ ends[0]);

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(5, 7)),
                                     tuple(makeConfig(PositionType.line), SourcePos(5, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(takeName!'='(state), str));
                    assert(equal(state.input, ends[1]));
                    assert(state.pos == t[1]);
                }
            }
        }

        foreach(haystack; AliasSeq!("4", "42", "-", ".", " ", "\t", "\n", "\r", " foo", "\tfoo", "\nfoo", "\rfoo"))
        {
            foreach(config; AliasSeq!(Config.init, makeConfig(PositionType.line), makeConfig(PositionType.none)))
            {
                assertThrown!XMLParsingException(testParser!config(haystack.save).takeName());
                assertThrown!XMLParsingException(testParser!config(haystack.save).takeName!'='());
            }
        }

        foreach(haystack; AliasSeq!("fo o=bar", "\nfoo=bar", "foo", "f", "=bar"))
        {
            foreach(config; AliasSeq!(Config.init, makeConfig(PositionType.line), makeConfig(PositionType.none)))
                assertThrown!XMLParsingException(testParser!config(haystack.save).takeName!'='());
        }
    }
}


// S := (#x20 | #x9 | #xD | #XA)+
bool isSpace(C)(C c)
    if(isSomeChar!C)
{
    switch(c)
    {
        case ' ':
        case '\t':
        case '\r':
        case '\n': return true;
        default : return false;
    }
}

unittest
{
    foreach(char c; char.min .. char.max)
    {
        if(c == ' ' || c == '\t' || c == '\r' || c == '\n')
            assert(isSpace(c));
        else
            assert(!isSpace(c));
    }
    foreach(wchar c; wchar.min .. wchar.max / 100)
    {
        if(c == ' ' || c == '\t' || c == '\r' || c == '\n')
            assert(isSpace(c));
        else
            assert(!isSpace(c));
    }
    foreach(dchar c; dchar.min .. dchar.max / 1000)
    {
        if(c == ' ' || c == '\t' || c == '\r' || c == '\n')
            assert(isSpace(c));
        else
            assert(!isSpace(c));
    }
}


// NameStartChar ::= ":" | [A-Z] | "_" | [a-z] | [#xC0-#xD6] | [#xD8-#xF6] | [#xF8-#x2FF] | [#x370-#x37D] |
//                   [#x37F-#x1FFF] | [#x200C-#x200D] | [#x2070-#x218F] | [#x2C00-#x2FEF] | [#x3001-#xD7FF] |
//                   [#xF900-#xFDCF] | [#xFDF0-#xFFFD] | [#x10000-#xEFFFF]
bool isNameStartChar(dchar c)
{
    import std.ascii : isAlpha;

    if(isAlpha(c))
        return true;
    if(c == ':' || c == '_')
        return true;
    if(c >= 0xC0 && c <= 0xD6)
        return true;
    if(c >= 0xD8 && c <= 0xF6)
        return true;
    if(c >= 0xF8 && c <= 0x2FF)
        return true;
    if(c >= 0x370 && c <= 0x37D)
        return true;
    if(c >= 0x37F && c <= 0x1FFF)
        return true;
    if(c >= 0x200C && c <= 0x200D)
        return true;
    if(c >= 0x2070 && c <= 0x218F)
        return true;
    if(c >= 0x2C00 && c <= 0x2FEF)
        return true;
    if(c >= 0x3001 && c <= 0xD7FF)
        return true;
    if(c >= 0xF900 && c <= 0xFDCF)
        return true;
    if(c >= 0xFDF0 && c <= 0xFFFD)
        return true;
    if(c >= 0x10000 && c <= 0xEFFFF)
        return true;
    return false;
}

unittest
{
    import std.range : only;
    import std.typecons : tuple;

    foreach(c; char.min .. cast(char)128)
    {
        if(c == ':' || c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z')
            assert(isNameStartChar(c));
        else
            assert(!isNameStartChar(c));
    }

    foreach(t; only(tuple(0xC0, 0xD6),
                    tuple(0xD8, 0xF6),
                    tuple(0xF8, 0x2FF),
                    tuple(0x370, 0x37D),
                    tuple(0x37F, 0x1FFF),
                    tuple(0x200C, 0x200D),
                    tuple(0x2070, 0x218F),
                    tuple(0x2C00, 0x2FEF),
                    tuple(0x3001, 0xD7FF),
                    tuple(0xF900, 0xFDCF),
                    tuple(0xFDF0, 0xFFFD),
                    tuple(0x10000, 0xEFFFF)))
    {
        assert(!isNameStartChar(t[0] - 1));
        assert(isNameStartChar(t[0]));
        assert(isNameStartChar(t[0] + 1));
        assert(isNameStartChar(t[0] + (t[1] - t[0])));
        assert(isNameStartChar(t[1] - 1));
        assert(isNameStartChar(t[1]));
        assert(!isNameStartChar(t[1] + 1));
    }
}


// NameStartChar ::= ":" | [A-Z] | "_" | [a-z] | [#xC0-#xD6] | [#xD8-#xF6] | [#xF8-#x2FF] | [#x370-#x37D] |
//                   [#x37F-#x1FFF] | [#x200C-#x200D] | [#x2070-#x218F] | [#x2C00-#x2FEF] | [#x3001-#xD7FF] |
//                   [#xF900-#xFDCF] | [#xFDF0-#xFFFD] | [#x10000-#xEFFFF]
// NameChar      ::= NameStartChar | "-" | "." | [0-9] | #xB7 | [#x0300-#x036F] | [#x203F-#x2040]
bool isNameChar(dchar c)
{
    import std.ascii : isDigit;
    return isNameStartChar(c) || isDigit(c) || c == '-' || c == '.' || c == 0xB7 ||
           c >= 0x0300 && c <= 0x036F || c >= 0x203F && c <= 0x2040;
}

unittest
{
    import std.range : only;
    import std.typecons : tuple;

    foreach(c; char.min .. cast(char)128)
    {
        if(c == ':' || c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
           c == '-' || c == '.' || c >= '0' && c <= '9')
        {
            assert(isNameChar(c));
        }
        else
            assert(!isNameChar(c));
    }

    assert(!isNameChar(0xB7 - 1));
    assert(isNameChar(0xB7));
    assert(!isNameChar(0xB7 + 1));

    foreach(t; only(tuple(0xC0, 0xD6),
                    tuple(0xD8, 0xF6),
                    tuple(0xF8, 0x037D), // 0xF8 - 0x2FF, 0x0300 - 0x036F, 0x37 - 0x37D
                    tuple(0x37F, 0x1FFF),
                    tuple(0x200C, 0x200D),
                    tuple(0x2070, 0x218F),
                    tuple(0x2C00, 0x2FEF),
                    tuple(0x3001, 0xD7FF),
                    tuple(0xF900, 0xFDCF),
                    tuple(0xFDF0, 0xFFFD),
                    tuple(0x10000, 0xEFFFF),
                    tuple(0x203F, 0x2040)))
    {
        assert(!isNameChar(t[0] - 1));
        assert(isNameChar(t[0]));
        assert(isNameChar(t[0] + 1));
        assert(isNameChar(t[0] + (t[1] - t[0])));
        assert(isNameChar(t[1] - 1));
        assert(isNameChar(t[1]));
        assert(!isNameChar(t[1] + 1));
    }
}


// Similar to Phobos' stripRight, but it only strips XML whitespace, and it
// works on non-bidirectional ranges, as ugly as that is (it would be so much
// nicer if we didn't care about having dxml be flexible enough to work with
// arbitrary ranges of characters). It is expected however that what's being
// passed to stripRightWS is the result of a previous call to takeExactly.
R stripRightWS(R)(R range)
    if(isForwardRange!R && isSomeChar!(ElementType!R) && is(typeof(takeExactly(range, 42)) == R))
{
    static if(isBidirectionalRange!R)
    {
        while(!range.empty && isSpace(range.back))
            range.popBack();
        return range;
    }
    else
    {
        size_t wsLen = 0;
        auto orig = range.save;
        while(!range.empty)
        {
            if(isSpace(range.front))
                ++wsLen;
            else
                wsLen = 0;
            range.popFront();
        }
        return takeExactly(orig, orig.length - wsLen);
    }
}

unittest
{
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    foreach(t; AliasSeq!(tuple("hello", "hello"), tuple("hello \t\r\n", "hello"),
                         tuple("  a  aca ana ra . a", "  a  aca ana ra . a"),
                         tuple("  a  aca ana ra . a ", "  a  aca ana ra . a"),
                         tuple("hello\v", "hello\v")))
    {
        foreach(func; testRangeFuncs)
            assert(equal(stripRightWS(byCodeUnit(t[0])), t[1]));
    }
}


pragma(inline, true) void popFrontAndIncCol(PS)(PS state)
{
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");
    state.input.popFront();
    nextCol!(PS.config)(state.pos);
}

pragma(inline, true) void nextLine(Config config)(ref SourcePos pos)
{
    static if(config.posType != PositionType.none)
        ++pos.line;
    static if(config.posType == PositionType.lineAndCol)
        pos.col = 1;
}

pragma(inline, true) void nextCol(Config config)(ref SourcePos pos)
{
    static if(config.posType == PositionType.lineAndCol)
        ++pos.col;
}

pragma(inline, true) void checkNotEmpty(PS)(PS state, size_t line = __LINE__)
{
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");
    if(state.input.empty)
        throw new XMLParsingException("Prematurely reached end of document", state.pos, __FILE__, line);
}


version(unittest)
{
    // Wrapping it like this rather than assigning testRangeFuncs directly
    // allows us to avoid having the imports be at module-level, which is
    // generally not esirable with version(unittest).
    alias testRangeFuncs = _testRangeFuncs!();
    template _testRangeFuncs()
    {
        import std.conv : to;
        import std.algorithm : filter;
        import std.meta : AliasSeq;
        alias _testRangeFuncs = AliasSeq!(a => to!string(a), a => to!wstring(a), a => to!dstring(a),
                                          a => filter!"true"(a), a => fwdCharRange(a), a => rasRefCharRange(a),
                                          a => byCodeUnit(a));
    }
}
