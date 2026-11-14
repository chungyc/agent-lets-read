{-# LANGUAGE OverloadedStrings #-}

module LetsRead.Chunker.Html
  ( stripTagBlocks
  , stripComments
  , decodeEntity
  , decodeEntities
  , translateTag
  , convertTags
  , htmlToMarkdown
  ) where

import Data.Char (chr, isAlphaNum, isDigit, isHexDigit, isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import LetsRead.Chunker.Markdown (normalizeMarkdown)
import Numeric (readHex)

-- | Strip specific container tags and their entire contents (e.g. <script>...</script>)
stripTagBlocks :: Text -> Text -> Text
stripTagBlocks tagName = go
  where
    openPat = "<" <> T.toLower tagName
    closePat = "</" <> T.toLower tagName <> ">"
    go txt =
      let lowerTxt = T.toLower txt
          (beforeIdx, restLower) = T.breakOn openPat lowerTxt
       in if T.null restLower
            then txt
            else
              let prefixLen = T.length beforeIdx
                  beforeOrig = T.take prefixLen txt
                  afterOpenOrig = T.drop prefixLen txt
                  afterOpenLower = restLower
                  afterTagName = T.drop (T.length openPat) afterOpenLower
                  validTag =
                    case T.uncons afterTagName of
                      Nothing -> False
                      Just (c, _) -> isSpace c || c == '>' || c == '/'
               in if not validTag
                    then
                      let step = T.length openPat
                       in beforeOrig <> T.take step afterOpenOrig <> go (T.drop step afterOpenOrig)
                    else
                      let (untilClose, afterCloseLower) = T.breakOn closePat afterOpenLower
                       in if T.null afterCloseLower
                            then beforeOrig
                            else
                              let dropLen = T.length untilClose + T.length closePat
                               in beforeOrig <> go (T.drop dropLen afterOpenOrig)

stripComments :: Text -> Text
stripComments txt =
  let (before, rest) = T.breakOn "<!--" txt
   in if T.null rest
        then txt
        else
          let (_, afterClose) = T.breakOn "-->" (T.drop 4 rest)
           in if T.null afterClose
                then before
                else before <> stripComments (T.drop 3 afterClose)

decodeEntity :: Text -> Text
decodeEntity ent =
  case ent of
    "amp" -> "&"
    "lt" -> "<"
    "gt" -> ">"
    "quot" -> "\""
    "apos" -> "'"
    "nbsp" -> " "
    "mdash" -> "—"
    "ndash" -> "–"
    "hellip" -> "…"
    "lsquo" -> "‘"
    "rsquo" -> "’"
    "ldquo" -> "“"
    "rdquo" -> "”"
    "copy" -> "©"
    _
      | Just hexTxt <- T.stripPrefix "#x" (T.toLower ent)
      , not (T.null hexTxt) && T.all isHexDigit hexTxt ->
          case readHex (T.unpack hexTxt) of
            [(n, "")] | n > 0 && n <= 0x10FFFF -> T.singleton (chr n)
            _ -> "&" <> ent <> ";"
      | Just decTxt <- T.stripPrefix "#" ent
      , not (T.null decTxt) && T.all isDigit decTxt ->
          let n = read (T.unpack decTxt) :: Int
           in if n > 0 && n <= 0x10FFFF
                then T.singleton (chr n)
                else "&" <> ent <> ";"
      | otherwise -> "&" <> ent <> ";"

decodeEntities :: Text -> Text
decodeEntities txt =
  let (before, rest) = T.breakOn "&" txt
   in if T.null rest
        then txt
        else
          let afterAmp = T.drop 1 rest
              (candidate, afterSemi) = T.span (\c -> c /= ';' && c /= '&' && not (isSpace c)) afterAmp
           in if not (T.null candidate) && T.length candidate <= 12 && ";" `T.isPrefixOf` afterSemi
                then before <> decodeEntity candidate <> decodeEntities (T.drop 1 afterSemi)
                else before <> "&" <> decodeEntities afterAmp

translateTag :: Text -> Text
translateTag rawTag =
  let inner = T.strip (T.drop 1 (T.dropEnd 1 rawTag))
      isClosing = "/" `T.isPrefixOf` inner
      cleaned = T.strip (if isClosing then T.drop 1 inner else inner)
      tagName = T.toLower (T.takeWhile (\c -> isAlphaNum c || c == ':' || c == '-') cleaned)
   in case (isClosing, tagName) of
        (False, "h1") -> "\n\n# "
        (False, "h2") -> "\n\n## "
        (False, "h3") -> "\n\n### "
        (False, "h4") -> "\n\n#### "
        (False, "h5") -> "\n\n##### "
        (False, "h6") -> "\n\n###### "
        (True, "h1") -> "\n\n"
        (True, "h2") -> "\n\n"
        (True, "h3") -> "\n\n"
        (True, "h4") -> "\n\n"
        (True, "h5") -> "\n\n"
        (True, "h6") -> "\n\n"
        (False, "p") -> "\n\n"
        (True, "p") -> "\n\n"
        (False, "div") -> "\n\n"
        (True, "div") -> "\n\n"
        (False, "section") -> "\n\n"
        (True, "section") -> "\n\n"
        (False, "article") -> "\n\n"
        (True, "article") -> "\n\n"
        (False, "blockquote") -> "\n\n> "
        (True, "blockquote") -> "\n\n"
        (False, "li") -> "\n- "
        (True, "li") -> "\n"
        (False, "br") -> "\n"
        (False, "hr") -> "\n\n* * *\n\n"
        (_, "em") -> "*"
        (_, "i") -> "*"
        (_, "strong") -> "**"
        (_, "b") -> "**"
        _ -> ""

convertTags :: Text -> Text
convertTags txt =
  let (before, rest) = T.breakOn "<" txt
   in if T.null rest
        then txt
        else
          let (tagBody, afterClose) = T.breakOn ">" rest
           in if T.null afterClose
                then before
                else
                  let fullTag = tagBody <> ">"
                   in before <> translateTag fullTag <> convertTags (T.drop 1 afterClose)

htmlToMarkdown :: Text -> Text
htmlToMarkdown =
  normalizeMarkdown
    . decodeEntities
    . convertTags
    . stripComments
    . stripSkippedTags
  where
    skippedTags = ["script", "style", "head", "nav", "footer", "noscript", "svg", "math"]
    stripSkippedTags txt = foldr stripTagBlocks txt skippedTags
