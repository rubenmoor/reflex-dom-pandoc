{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Reflex.Dom.Pandoc.Document
  ( elPandoc,
    elPandocInlines,
    elPandocBlocks,
    Config (..),
    PandocRawNode (..),
    defaultConfig,
  )
where

import Control.Monad (guard, void)
import Control.Monad.Reader
  ( MonadReader (ask),
    MonadTrans (lift),
    ReaderT (runReaderT),
  )
import Data.Bool (bool)
import qualified Data.Map as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import Reflex.Dom.Core hiding (Link, Space, mapAccum)
import Reflex.Dom.Pandoc.Footnotes
import Reflex.Dom.Pandoc.Raw (PandocRawNode (..), elPandocRawNodeSafe)
import Reflex.Dom.Pandoc.SyntaxHighlighting (elCodeHighlighted)
import Reflex.Dom.Pandoc.Util (elPandocAttr, headerElement, plainify, renderAttr, sansEmptyAttrs)
import Text.Pandoc.Definition

data Config t m a = Config
  { -- | Custom link renderer.
    _config_renderLink ::
      m a ->
      -- Link URL
      Text ->
      -- Link attributes, including "title"
      Map Text Text ->
      -- Inner body of the link. Nothing if same as URL (i.e., an autolink)
      Maybe [Inline] ->
      m a,
    -- | How to render code blocks
    _config_renderCode ::
      m () ->
      Attr ->
      Text ->
      m (),
    -- | How to render raw nodes
    _config_renderRaw ::
      PandocRawNode ->
      m a
  }

defaultConfig :: DomBuilder t m => Config t m ()
defaultConfig =
  Config
    (\f _ _ _ -> f >> pure ())
    (\f _ _ -> f)
    elPandocRawNodeSafe

-- | Convert Markdown to HTML
elPandoc :: forall t m a. (DomBuilder t m, Monoid a) => Config t m a -> Pandoc -> m a
elPandoc cfg doc@(Pandoc _meta blocks) = do
  let fs = queryFootnotes doc
  x <- flip runReaderT fs $ renderBlocks cfg blocks
  (x <>) <$> renderFootnotes (sansFootnotes . renderBlocks cfg) fs

-- | Render list of Pandoc inlines
elPandocInlines :: DomBuilder t m => [Inline] -> m ()
elPandocInlines = void . sansFootnotes . renderInlines defaultConfig

-- | Render list of Pandoc Blocks
elPandocBlocks :: DomBuilder t m => [Block] -> m ()
elPandocBlocks = void . sansFootnotes . renderBlocks defaultConfig

mapAccum :: (Monoid b, Applicative f) => (a -> f b) -> [a] -> f b
mapAccum f =
  fmap mconcat . traverse f

renderBlocks :: (DomBuilder t m, Monoid a) => Config t m a -> [Block] -> ReaderT Footnotes m a
renderBlocks cfg =
  mapAccum $ renderBlock cfg

renderBlock :: (DomBuilder t m, Monoid a) => Config t m a -> Block -> ReaderT Footnotes m a
renderBlock cfg = \case
  -- Pandoc parses github tasklist as this structure.
  Plain (Str "☐" : Space : is) -> checkboxEl False >> renderInlines cfg is
  Plain (Str "☒" : Space : is) -> checkboxEl True >> renderInlines cfg is
  Para (Str "☐" : Space : is) -> checkboxEl False >> renderInlines cfg is
  Para (Str "☒" : Space : is) -> checkboxEl True >> renderInlines cfg is
  Plain xs ->
    renderInlines cfg xs
  Para xs ->
    el "p" $ renderInlines cfg xs
  LineBlock xss ->
    flip mapAccum xss $ \xs -> do
      renderInlines cfg xs <* text "\n"
  CodeBlock attr x -> do
    lift $ _config_renderCode cfg (elCodeHighlighted attr x) attr x
    pure mempty
  RawBlock fmt x ->
    lift $ _config_renderRaw cfg (PandocRawNode_Block fmt x) >> pure mempty
  BlockQuote xs ->
    el "blockquote" $ renderBlocks cfg xs
  OrderedList (idx, style, _delim) xss ->
    -- delimStyle is not supported in HTML or in Semantic UI
    elAttr "ol" (listStyle style <> startFrom idx) $ do
      flip mapAccum xss $ \xs -> do
        el "li" $ renderBlocks cfg xs
  BulletList xss ->
    el "ul" $ flip mapAccum xss $ \xs -> el "li" $ renderBlocks cfg xs
  DefinitionList defs ->
    el "dl" $
      flip mapAccum defs $ \(term, descList) -> do
        x <- el "dt" $ renderInlines cfg term
        fmap (x <>) $
          flip mapAccum descList $ \desc ->
            el "dd" $ renderBlocks cfg desc
  Header level attr xs ->
    elPandocAttr (headerElement level) attr $ do
      renderInlines cfg xs
  HorizontalRule ->
    el "hr" blank >> pure mempty
  Table attr _captions _colSpec (TableHead _ hrows) tbodys _tfoot -> do
    -- TODO: Apply captions, colSpec, etc.
    elPandocAttr "table" attr $ do
      x <- el "thead" $ do
        flip mapAccum hrows $ \(Row _ cells) -> do
          el "tr" $ do
            flip mapAccum cells $ \(Cell _ _ _ _ blks) ->
              el "th" $ renderBlocks cfg blks
      fmap (x <>) $
        flip mapAccum tbodys $ \(TableBody _ _ _ rows) ->
          el "tbody" $ do
            flip mapAccum rows $ \(Row _ cells) ->
              el "tr" $ do
                flip mapAccum cells $ \(Cell _ _ _ _ blks) ->
                  el "td" $ renderBlocks cfg blks
  Figure attr _captions xs ->
    elPandocAttr "img" attr $ renderBlocks cfg xs
  Div attr xs ->
    elPandocAttr "div" attr $
      renderBlocks cfg xs
  where
    checkboxEl checked = do
      let attrs =
            mconcat $
              [ "type" =: "checkbox",
                "disabled" =: "True",
                bool mempty ("checked" =: "True") checked
              ]
      void $ elAttr "input" attrs blank
    startFrom idx = bool mempty ("start" =: T.pack (show idx)) (idx /= 1)
    listStyle = \case
      LowerRoman -> "type" =: "i"
      UpperRoman -> "type" =: "I"
      LowerAlpha -> "type" =: "a"
      UpperAlpha -> "type" =: "A"
      _ -> mempty

renderInlines :: (DomBuilder t m, Monoid a) => Config t m a -> [Inline] -> ReaderT Footnotes m a
renderInlines cfg =
  mapAccum $ renderInline cfg

renderInline :: (DomBuilder t m, Monoid a) => Config t m a -> Inline -> ReaderT Footnotes m a
renderInline cfg = \case
  Str x ->
    text x >> pure mempty
  Emph xs ->
    el "em" $ renderInlines cfg xs
  Strong xs ->
    el "strong" $ renderInlines cfg xs
  Underline xs ->
    el "u" $ renderInlines cfg xs
  Strikeout xs ->
    el "strike" $ renderInlines cfg xs
  Superscript xs ->
    el "sup" $ renderInlines cfg xs
  Subscript xs ->
    el "sub" $ renderInlines cfg xs
  SmallCaps xs ->
    el "small" $ renderInlines cfg xs
  Quoted qt xs ->
    flip inQuotes qt $ renderInlines cfg xs
  Cite _ _ -> do
    el "pre" $ text "error[reflex-doc-pandoc]: Pandoc Cite is not handled"
    pure mempty
  Code attr x ->
    elPandocAttr "code" attr $ do
      text x
      pure mempty
  Space ->
    text " " >> pure mempty
  SoftBreak ->
    text " " >> pure mempty
  LineBreak ->
    el "br" blank >> pure mempty
  RawInline fmt x ->
    lift $ _config_renderRaw cfg (PandocRawNode_Inline fmt x) >> pure mempty
  Math mathType s -> do
    -- http://docs.mathjax.org/en/latest/basic/mathematics.html#tex-and-latex-input
    case mathType of
      InlineMath ->
        elClass "span" "math inline" $ text $ "\\(" <> s <> "\\)"
      DisplayMath ->
        elClass "span" "math display" $ text "$$" >> text s >> text "$$"
    pure mempty
  Link attr xs (lUrl, lTitle) -> do
    let attrMap = renderAttr attr
        defaultRender = do
          let attr' = sansEmptyAttrs $ attrMap <> "href" =: lUrl <> "title" =: lTitle
          elAttr "a" attr' $ renderInlines cfg xs
    fns <- ask
    let minner = do
          guard $ xs /= [Str lUrl]
          pure xs
    lift $
      _config_renderLink
        cfg
        (runReaderT defaultRender fns)
        lUrl
        (attrMap <> "title" =: lTitle)
        minner
  Image attr xs target -> do
    elAttr "img" (imageAttrs attr xs target) blank >> pure mempty
  Note xs -> do
    fs :: Footnotes <- ask
    case Map.lookup (mkFootnote xs) fs of
      Nothing ->
        -- No footnote in the global map (this means that the user has
        -- defined a footnote inside a footnote); just put the whole thing in
        -- aside.
        elClass "aside" "footnote-inline" $ renderBlocks cfg xs
      Just idx ->
        renderFootnoteRef idx >> pure mempty
  Span attr xs ->
    elPandocAttr "span" attr $
      renderInlines cfg xs
  where
    inQuotes w = \case
      SingleQuote -> text "‘" >> w <* text "’"
      DoubleQuote -> text "“" >> w <* text "”"
    -- Pandoc stores Img's alt text as [Inline]
    imageAttrs attr imgInlines (iUrl, iTitle) =
      sansEmptyAttrs $ renderAttr attr <> ("src" =: iUrl <> "title" =: iTitle <> "alt" =: plainify imgInlines)
