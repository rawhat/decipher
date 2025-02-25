// IMPORTS ---------------------------------------------------------------------

import birl.{type Time}
import gleam/dict
import gleam/dynamic.{type DecodeError, type Decoder, type Dynamic, DecodeError}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/pair
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam/uri.{type Uri}

// PRIMITIVES ------------------------------------------------------------------

/// Decode an `Int` as long as it is greater than or equal to zero.
///
pub fn non_negative_int(dynamic: Dynamic) -> Result(Int, List(DecodeError)) {
  use int <- result.try(dynamic.int(dynamic))

  case int >= 0 {
    True -> Ok(int)
    False ->
      Error([
        DecodeError(
          expected: "A non-negative int",
          found: int.to_string(int),
          path: [],
        ),
      ])
  }
}

/// Decode an `Int` that has been converted to a string. Some JSON APIs will
/// send numbers as strings, so this decoder can come in handy more often than
/// you'd think!
///
pub fn int_string(dynamic: Dynamic) -> Result(Int, List(DecodeError)) {
  use string <- result.try(dynamic.string(dynamic))

  string
  |> int.parse
  |> result.replace_error([
    DecodeError(expected: "A stringified int", found: string, path: []),
  ])
}

/// Decode a `Float` that has been converted to a string. Some JSON APIs will
/// send numbers as strings, so this decoder can come in handy more often than
/// you'd think!
///
pub fn float_string(dynamic: Dynamic) -> Result(Float, List(DecodeError)) {
  use string <- result.try(dynamic.string(dynamic))

  string
  |> float.parse
  |> result.replace_error([
    DecodeError(expected: "A stringified float", found: string, path: []),
  ])
}

/// This decoder is capable of decoding both `Int` and `Float` values. If the
/// value is an `Int`, it will be converted to a `Float` automatically.
///
pub fn number(dynamic: Dynamic) -> Result(Float, List(DecodeError)) {
  dynamic.any([
    dynamic.float,
    fn(dynamic) {
      dynamic.int(dynamic)
      |> result.map(int.to_float)
    },
  ])(dynamic)
}

/// Decode numbers that have been converted to strings. This decoder is capable
/// of decoding both `Int` and `Float` values converted to strings. Some JSON
/// APIs will send numbers as strings, so this decoder can come in handy more
/// often than you'd think!
///
pub fn number_string(dynamic: Dynamic) -> Result(Float, List(DecodeError)) {
  dynamic.any([
    float_string,
    fn(dynamic) {
      int_string(dynamic)
      |> result.map(int.to_float)
    },
  ])(dynamic)
}

/// Decode a string that represents a YAML-style boolean value. Any of the following
/// values will be decoded as `True`:
///
/// - "true"
/// - "True"
/// - "on"
/// - "On"
/// - "yes"
/// - "Yes"
///
/// Any of the following values will be decoded as `False`:
///
/// - "false"
/// - "False"
/// - "off"
/// - "Off"
/// - "no"
/// - "No"
///
/// Anything else will fail to decode.
///
pub fn bool_string(dynamic: Dynamic) -> Result(Bool, List(DecodeError)) {
  enum([
    #("true", True),
    #("True", True),
    #("on", True),
    #("On", True),
    #("yes", True),
    #("Yes", True),
    #("false", False),
    #("False", False),
    #("off", False),
    #("Off", False),
    #("no", False),
    #("No", False),
  ])(dynamic)
}

/// This decoder will decode a string and then confirm that it is not empty.
///
pub fn nonempty_string(dynamic: Dynamic) -> Result(String, List(DecodeError)) {
  use string <- result.try(dynamic.string(dynamic))

  case string {
    "" ->
      Error([
        DecodeError(
          expected: "A non-empty string",
          found: "An empty string",
          path: [],
        ),
      ])
    _ -> Ok(string)
  }
}

// COLLECTIONS -----------------------------------------------------------------

/// Decode a list or [arraylike](#arraylike) into a `Set`. Any duplicate values
/// will be _dropped_. If you want to ensure that there are no duplicates, use
/// the [exact_set](#exact_set) decoder instead.
///
pub fn set(decoder: Decoder(a)) -> Decoder(Set(a)) {
  fn(dynamic: Dynamic) {
    dynamic
    |> dynamic.any([dynamic.list(decoder), arraylike(decoder)])
    |> result.map(set.from_list)
  }
}

/// Decode a list or [arraylike](#arraylike) into a `Set`. This decoder is slightly
/// slower than the [set](#set) decoder, but it will guarantee that there were no
/// duplicate values in the incoming list.
///
pub fn exact_set(decoder: Decoder(a)) -> Decoder(Set(a)) {
  fn(dynamic: Dynamic) {
    use list <- result.try(
      dynamic.any([dynamic.list(decoder), arraylike(decoder)])(dynamic),
    )
    let length = list.length(list)
    let set = set.from_list(list)

    case set.size(set) == length {
      True -> Ok(set)
      False ->
        Error([
          DecodeError(
            expected: "A list with no duplicate values",
            found: "A list with duplicate values",
            path: [],
          ),
        ])
    }
  }
}

/// Decode a list or [arraylike](#arraylike) with at least one item into a `List`.
/// If the incoming list is empty, decoding will fail.
///
pub fn nonempty_list(decode: Decoder(a)) -> Decoder(List(a)) {
  fn(dynamic: Dynamic) {
    use list <- result.try(dynamic.list(decode)(dynamic))

    case list.is_empty(list) {
      True ->
        Error([
          DecodeError(
            expected: "A non-empty list",
            found: "A list with at least 1 item",
            path: [],
          ),
        ])
      False -> Ok(list)
    }
  }
}

/// In JavaScript certain objects are said to be "arraylike". These are objects
/// that satisfy the following conditions:
///
/// - They have a `length` property that is a non-negative integer.
/// - They have a property for each integer index from `0` up to `length - 1`.
///
/// Operations like `document.querySelectorAll` or `document.getElementsByTagName`
/// return arraylike objects like a [`NodeList`](https://developer.mozilla.org/en-US/docs/Web/API/NodeList).
/// This decoder is capable of decoding such objects into a proper Gleam `List`.
///
pub fn arraylike(decoder: Decoder(a)) -> Decoder(List(a)) {
  fn(dynamic: Dynamic) {
    use length <- result.try(dynamic.field("length", dynamic.int)(dynamic))

    all({
      let list = list.range(0, length - 1)
      use index <- list.map(list)

      dynamic.field(int.to_string(index), decoder)
    })(dynamic)
  }
}

/// Create a decoder for a list of values from a list of decoders to run. Each
/// decoder will run against the input value, and all must succeed for the decoder
/// to succeed.
///
/// Errors from each decoder will be collected, which means the entire list is
/// run even if one decoder fails!
///
pub fn all(decoders: List(Decoder(a))) -> Decoder(List(a)) {
  fn(dynamic: Dynamic) {
    use list, decoder <- list.fold_right(decoders, Ok([]))

    case list, decoder(dynamic) {
      Ok(xs), Ok(x) -> Ok([x, ..xs])
      Ok(_), Error(e) -> Error(e)
      Error(e), Ok(_) -> Error(e)
      Error(e), Error(x) -> Error(list.append(e, x))
    }
  }
}

// CUSTOM TYPES ----------------------------------------------------------------

/// There is no standard way to represent something like Gleam's custom types as
/// JSON or YAML (or most common formats). It's common then to represent them as
/// a _tagged_ or _discriminated_ union where a field is used to signify which
/// variant of the type is being represented.
///
/// This decoder lets you decode things in this format by first decoding the tag
/// and then selecting the appropriate decoder to run based on that tag.
///
/// ```gleam
/// import decipher
/// import gleam/dynamic.{type DecodeError, type Decoder, type Dynamic, DecodeError}
///
/// type Example {
///   Wibble(foo: Int)
///   Wobble(bar: String)
/// }
///
/// fn example_decoder(dynamic: Dynamic) -> Result(Example, List(DecodeError)) {
///   decipher.tagged_union(
///     dynamic.field("$", dynamic.string),
///     [
///       dynamic.decode1(Wibble, dynamic.field("foo", dynamic.int)),
///       dynamic.decode1(Wobble, dynamic.field("bar", dynamic.string)),
///     ]
///   )
/// }
/// ```
///
pub fn tagged_union(
  tag_decoder: Decoder(a),
  variants: List(#(a, Decoder(b))),
) -> Decoder(b) {
  let switch = dict.from_list(variants)

  fn(dynamic: Dynamic) {
    use tag <- result.try(tag_decoder(dynamic))

    case dict.get(switch, tag) {
      Ok(decoder) -> decoder(dynamic)
      Error(_) -> {
        // We're going to report the possible tags as a TS-style union, so
        // something like:
        //
        //   "A" | "B" | "C"
        //
        let tags =
          dict.keys(switch)
          |> list.map(string.inspect)
          |> string.join(" | ")

        // Recover the path from the user's `tag_decoder`. This is kind of hacky
        // but honestly if they somehow succeed in decoding `Nil` then what are
        // they even playing at.
        //
        let path = case tag_decoder(dynamic.from(Nil)) {
          Error([DecodeError(path: path, ..), ..]) -> path
          _ -> []
        }

        Error([
          DecodeError(expected: tags, found: string.inspect(tag), path: path),
        ])
      }
    }
  }
}

/// A simplified version of the [tagged_union](#tagged_union) decoder. First
/// decodes a string, and then attempts to find a corresponding value from a
/// list of variants.
///
/// This is how the [`bool_string`](#bool_string) decoder is implemented:
///
/// ```gleam
/// import decipher
/// import gleam/dynamic.{type DecodeError, type Decoder, type Dynamic, DecodeError}
///
/// pub fn bool_string(dynamic: Dynamic) -> Result(Bool, List(DecodeError)) {
///   decipher.enum([
///     #("true", True),
///     #("True", True),
///     #("on", True),
///     #("On", True),
///     #("yes", True),
///     #("Yes", True),
///     #("false", False),
///     #("False", False),
///     #("off", False),
///     #("Off", False),
///     #("no", False),
///     #("No", False),
///   ])(dynamic)
/// }
/// ```
///
pub fn enum(variants: List(#(String, a))) -> Decoder(a) {
  tagged_union(
    dynamic.string,
    list.map(variants, pair.map_second(_, fn(variant) { fn(_) { Ok(variant) } })),
  )
}

// EXOTICS ---------------------------------------------------------------------

/// Decode a string representing an [ISO 8601 datetime](https://en.wikipedia.org/wiki/ISO_8601)
/// as a [`Time`](https://hexdocs.pm/birl/birl.html#Time) value from the birl
/// package.
///
pub fn iso_8601(dynamic: Dynamic) -> Result(Time, List(DecodeError)) {
  use string <- result.try(dynamic.string(dynamic))

  case birl.parse(string) {
    Ok(time) -> Ok(time)
    Error(_) ->
      Error([
        DecodeError(
          expected: "An ISO 8601 date string",
          found: string,
          path: [],
        ),
      ])
  }
}

/// Decode a [Unix timestamp](https://en.wikipedia.org/wiki/Unix_time) as a
/// [`Time`](https://hexdocs.pm/birl/birl.html#Time) value from the birl package.
///
pub fn unix_timestamp(dynamic: Dynamic) -> Result(Time, List(DecodeError)) {
  dynamic
  |> dynamic.any([dynamic.int, int_string])
  |> result.map(birl.from_unix)
}

/// Decode a string representing a [HTTP-date](https://www.rfc-editor.org/rfc/rfc9110#http.date)
/// as a [`Time`](https://hexdocs.pm/birl/birl.html#Time) value from the birl
/// package.
///
pub fn http_date(dynamic: Dynamic) -> Result(Time, List(DecodeError)) {
  use string <- result.try(dynamic.string(dynamic))

  case birl.from_http(string) {
    Ok(time) -> Ok(time)
    Error(_) ->
      Error([
        DecodeError(expected: "An HTTP date string", found: string, path: []),
      ])
  }
}

/// Decode a string representing a [URI](https://en.wikipedia.org/wiki/Uniform_Resource_Identifier)
/// into a Gleam [`Uri`](https://hexdocs.pm/gleam_stdlib/gleam/uri.html#Uri) value.
///
pub fn uri(dynamic: Dynamic) -> Result(Uri, List(DecodeError)) {
  use string <- result.try(dynamic.string(dynamic))

  case uri.parse(string) {
    Ok(uri) -> Ok(uri)
    Error(_) ->
      Error([
        DecodeError(expected: "A valid Gleam URI", found: string, path: []),
      ])
  }
}

// UTILITIES -------------------------------------------------------------------

/// Run a decoder but only keep the result if it satisfies the given predicate.
/// This is how decoders like [`non_negative_int`](#non_negative_int) can be
/// implemented:
///
/// ```gleam
/// import decipher
/// import gleam/dynamic.{type DecodeError, type Decoder, type Dynamic, DecodeError}
///
/// pub fn non_negative_int(dynamic: Dynamic) -> Result(Int, List(DecodeError)) {
///   decipher.when(dynamic.int, is: fn(x) { x >= 0 })(dynamic)
/// }
/// ```
///
pub fn when(decoder: Decoder(a), is predicate: fn(a) -> Bool) -> Decoder(a) {
  fn(dynamic: Dynamic) {
    use value <- result.try(decoder(dynamic))

    case predicate(value) {
      True -> Ok(value)
      False ->
        Error([
          DecodeError(
            expected: "A value that satisfies the predicate",
            found: string.inspect(value),
            path: [],
          ),
        ])
    }
  }
}

/// Occasionally you might find yourself in the situation where a JSON string is
/// embedded in the dynamic value you're trying to decode. This decoder lets you
/// extract that JSON and then run the decoder against it.
///
pub fn json_string(decoder: Decoder(a)) -> Decoder(a) {
  fn(dynamic: Dynamic) {
    use json <- result.try(dynamic.string(dynamic))

    case json.decode(json, decoder) {
      Ok(a) -> Ok(a)
      Error(json.UnexpectedFormat(errors)) -> Error(errors)
      Error(_) ->
        Error([
          DecodeError(
            expected: "A valid JSON-encoded string",
            found: json,
            path: [],
          ),
        ])
    }
  }
}
