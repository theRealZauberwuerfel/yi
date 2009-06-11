{-# LANGUAGE FlexibleInstances, TypeFamilies, TemplateHaskell, DeriveDataTypeable #-}
-- Copyright (c) JP Bernardy 2008
-- Note if the layout of the first line (not comments)
-- is wrong the parser will only parse what is in the blocks given by Layout.hs
module Yi.Syntax.Haskell ( Program (..)
                         , PModule (..)
                         , PImport (..)
                         , Exp (..)
                         , Tree
                         , parse
                         , indentScanner
                         , getExprs
                         ) where

import Prelude ()
import Data.Maybe
import Data.List (filter, union, takeWhile, (\\))
import Yi.IncrementalParse
import Yi.Lexer.Alex
import Yi.Lexer.Haskell
import Yi.Syntax.Layout
import Yi.Syntax.Tree
import qualified Yi.Syntax.BList as BL
import Yi.Syntax
import Yi.Prelude
import Prelude ()
import Data.Monoid
import Data.DeriveTH
import Data.Derive.Foldable
import Data.Maybe

indentScanner :: Scanner (AlexState lexState) (TT)
              -> Scanner (Yi.Syntax.Layout.State Token lexState) (TT)
indentScanner = layoutHandler startsLayout [(Special '(', Special ')'),
                                            (Special '[', Special ']'),
                                            (Special '{', Special '}')]
                         ignoredToken
                         ([(Special '<'), (Special '>'), (Special '.')])
                         isBrace

-- HACK: We insert the Special '<', '>', '.', which do not occur in normal haskell
-- parsing.

isBrace :: TT -> Bool
isBrace (Tok b _ _) = (Special '{') == b

ignoredToken :: TT -> Bool
ignoredToken (Tok t _ (Posn _ _ _)) = isComment t || t == CppDirective

type Tree t = Program t
type PAtom t = Exp t
type Block t = Exp t
type PGuard t = Exp t

-- | A program is some comments followed by a module and a body
data Program t
    = Program [t] (Maybe (Program t)) -- a program can be just comments
    | ProgMod (PModule t) (Program t)
    | Body [PImport t] (Block t) (Block t)
  deriving (Show)

-- | A module
data PModule t = PModule (PAtom t) (PAtom t) (Exp t) (Exp t)
    deriving (Show)

-- | Imported things
data PImport t = PImport (PAtom t) (Exp t) (PAtom t) (Exp t) (Exp t)
    deriving (Show)

-- | Exp can be expression or declaration
data Exp t
      -- A parenthesized expression with comments
    = Paren (PAtom t) (Exp t) (PAtom t)
      -- Special parenthesis to increase speed of parser
    | SParen (PAtom t) (Exp t)
    | SParen' (Exp t) (PAtom t) (Exp t)
      -- A list of things separated by layout (as in do; etc.)
    | Block (BL.BList [Exp t])
    | PAtom t [t]
    | PFun (Exp t) (Exp t) t [t] (Exp t)
    | Expr [Exp t]
    | KW (PAtom t) (Exp t)
    | PWhere t [t] (Exp t)
    | Bin (Exp t) (Exp t)
       -- an error with comments following so we never color comments in wrong
       -- color. The error has an extra token, the Special '!' token to indicate
       -- that it contains an error
    | PError t t [t]
      -- rhs that begins with Equal
    | RHS (PAtom t) [Exp t]
    | Opt (Maybe (Exp t))
    | Modid t [t]
    | Op t [t] (Exp t)
    | Context (Exp t) (Exp t) t [t]
    | PType t [t] (Exp t) (Exp t) t [t] (Exp t)
    | PData t [t] (Exp t) (Exp t) (Exp t)
    | PData' t [t] (Exp t) (Exp t)
    | PGuard [PGuard t]
    | PGuard' t (Exp t) t (Exp t)
      -- type constructor
    | TC (Exp t)
      -- type signature
    | TS t [Exp t]
      -- data constructor
    | DC (Exp t)
    | PLet t [t] (Exp t) (Exp t)
    | PIn t [Exp t]
      -- keyword, Opt scontext, tycls, tyvar, Opt where
    | PClass (PAtom t) (Exp t) (Exp t) (Exp t) (Exp t)
      -- keyword, Opt scontext, tycls, Inst, where
    | PInstance (PAtom t) (Exp t) (Exp t) (Exp t) (Exp t)
  deriving (Show)

instance SubTree (Exp TT) where
    type Element (Exp TT) = TT
    foldMapToksAfter begin f t0 = work t0
        where work (Paren e e' e'') = work e <> work e' <> work e''
              work (PFun e e' t lt e'')
                     = work e
                    <> work e'
                    <> f t
                    <> fold' lt
                    <> work e''
              work (Expr e)     = foldMap work e
              work (KW e e')    = work e <> work e'
              work (PWhere t c e) = f t <> fold' c <> work e
              work (Bin e e')   = work e <> work e'
              work (RHS e l)    = work e <> foldMap work l
              work (Opt (Just t)) = work t
              work (Opt Nothing)  = mempty
              work (Modid t l)    = f t
                                 <> fold' l
              work (Op t l e) = f t
                             <> fold' l
                             <> work e
              work (Context e e' t l) = f t
                                     <> work e
                                     <> work e'
                                     <> fold' l
              work (PType t l e e' t' l' e'') = f t
                                             <> fold' l
                                             <> work e
                                             <> work e'
                                             <> f t'
                                             <> fold' l'
                                             <> work e''
              work (PData t l e e' e'') = f t
                                       <> fold' l
                                       <> work e
                                       <> work e'
                                       <> work e''
              work (PData' t l e e') = f t
                                    <> fold' l
                                    <> work e
                                    <> work e'
              work (PGuard l) = foldMap work l
              work (PGuard' t e t' e') = f t
                                      <> work e
                                      <> f t'
                                      <> work e'
              work (PAtom t c)  = f t <> fold' c
              work (PError t' t c) = f t' <> f t <> fold' c
              work (TS t e) = f t <> foldMap work e
              work (DC e) = work e
              work (TC e) = work e
              work (PLet t l e e') = f t
                                  <> fold' l
                                  <> work e
                                  <> work e'
              work (PIn t l) = f t <> foldMap work l
              work (Block s) = BL.foldMapAfter
                                begin (foldMapToksAfter begin f) s
              work (PClass e e' e'' exp exp') = work e <> work e' <> work e''
                                             <> work exp <> work exp'
              work (PInstance e e' exp exp' e'' ) = work e <> work e'
                                                 <> work exp <> work exp' <> work e''
              work a = error $ "Instance SubTree: " ++ show a
              fold' = foldMapToksAfter begin f
    foldMapToks f = foldMap (foldMapToks f)

instance SubTree (Program TT) where
    type Element (Program TT) = TT
    foldMapToksAfter begin f t0 = work t0
        where work (Program m (Just p)) = foldMapToksAfter begin f m <> work p
              work (Program m Nothing) = foldMapToksAfter begin f m
              work (ProgMod _ p) = work p
              work (Body _ (Block t) (Block t')) = (BL.foldMapAfter
                                begin (foldMapToksAfter begin f) t)
                                       <> (BL.foldMapAfter
                                       begin (foldMapToksAfter begin f) t')
              work _ = undefined
    foldMapToks f = foldMap (foldMapToks f)

instance SubTree (PImport TT) where
    type Element (PImport TT) = TT
    foldMapToksAfter begin f t0 = work t0
        where work (PImport at e at' e' e'') = fold' at
                                            <> fold' e
                                            <> fold' at'
                                            <> fold' e'
                                            <> fold' e''
              fold' = foldMapToksAfter begin f
    foldMapToks f = foldMap (foldMapToks f)


type TTT = Exp TT


$(derive makeFoldable ''PImport)
$(derive makeFoldable ''PModule)
$(derive makeFoldable ''Program)

$(derive makeFoldable ''Exp)
instance IsTree Exp where
   subtrees tree = case tree of
       (Paren _ g _)  -> subtrees g
       (RHS _ g)      -> g
       (PWhere _ _ r) -> subtrees r
       (Block s)      -> concat s
       (PGuard s)     -> s
       (PLet _ _ s _) -> subtrees s
       (PIn _ ts)     -> ts
       (Expr a)       -> a
       _              -> []

-- | Search the given list, and return the 1st tree after the given
-- point on the given line.  This is the tree that will be moved if
-- something is inserted at the point.  Precondition: point is in the
-- given line.

-- TODO: this should be optimized by just giving the point of the end
-- of the line
getIndentingSubtree :: [Exp TT] -> Point -> Int -> Maybe (Exp TT)
getIndentingSubtree roots offset line =
    listToMaybe $ [t | (t,posn) <- takeWhile
                   ((<= line) . posnLine . snd) $ allSubTree'sPosn,
--                    -- it's very important that we do a linear search
--                    -- here (takeWhile), so that the tree is evaluated
--                    -- lazily and therefore parsing it can be lazy.
                   posnOfs posn > offset, posnLine posn == line]
    where allSubTree'sPosn = [(t',posn) | root <- roots,
                              t'@(Block _) <- filter (not . null . toList)
                              (getAllSubTrees root),
                             let (tok:_) = toList t',
                             let posn = tokPosn tok]

-- | given a tree, return (first offset, number of lines).
getSubtreeSpan :: Exp TT -> (Point, Int)
getSubtreeSpan tree = (posnOfs $ first, lastLine - firstLine)
    where bounds@[first, _last]
              = fmap (tokPosn . assertJust)
                [getFirstElement tree, getLastElement tree]
          [firstLine, lastLine] = fmap posnLine bounds
          assertJust (Just x) = x
          assertJust _ = error "assertJust: Just expected"

getExprs :: Program TT -> [Exp TT]
getExprs (ProgMod _ b)     = getExprs b
getExprs (Body _ exp exp') = [exp, exp']
getExprs (Program _ (Just e)) = getExprs e
getExprs _                 = [] -- error "no match"

-- | The parser
parse :: P TT (Tree TT)
parse = pProgram <* eof

-- | Parse a program
pProgram :: Parser TT (Program TT)
pProgram = Program <$> many pComment <*> optional
           (pBlockOf' ((ProgMod <$> pModule
                        <*> pModBody) <|> pBody))

-- | Parse a body that follows a module
pModBody :: Parser TT (Program TT)
pModBody = (Body <$> ((exact [Special '<']) *> pImp)
            <*> (((pBol *> pBod) <|> pEmptyBL) <* (exact [Special '>']))
            <*> pBod)
       <|> (Body <$> (exact [Special '.'] *>) pImp
            <*> ((pBol *> pBod) <|> pEmptyBL)
            <*> pEmptyBL)
       <|> (Body <$> pure [] <*> pEmptyBL <*> pEmptyBL)
    where pBol  = testNext (\r ->(not $ isJust r) ||
                            not (((flip elem elems) . tokT . fromJust) r))
          pBod  = (Block <$> pBlocks pDTree)
          elems = [(Special '.'),(Special '<')]

pEmptyBL :: Parser TT TTT
pEmptyBL = Block <$> pure BL.nil

-- | Parse a body of a program
pBody :: Parser TT (Program TT)
pBody = Body <$> pImp <*> (pBol *> (Block <$> pBlocks pDTree)) <*> pEmptyBL
    where pBol = testNext (\r ->(not $ isJust r) ||
                           not (((flip elem elems) . tokT . fromJust) r))
          elems = [(Special '.'),(Special '<')]

-- Helper functions for parsing follows
-- | Parse Variables
pVarId :: Parser TT (TTT)
pVarId = pAtom [VarIdent, (Reserved Other), (Reserved As)]

-- | Parse VarIdent and ConsIdent
pQvarid :: Parser TT TTT
pQvarid = pAtom [VarIdent, ConsIdent, (Reserved Other), (Reserved As)]

-- | Parse an operator using please
ppQvarsym :: Parser TT TTT
ppQvarsym = pTup $ pleaseC (PAtom <$> sym isOperator <*> many pComment)

-- | Parse any operator
isOperator :: Token -> Bool
isOperator (Operator _)     = True
isOperator (ReservedOp _)   = True
isOperator (ConsOperator _) = True
isOperator _                = False

-- | Parse a consident
pQtycon :: Parser TT TTT
pQtycon = pAtom [ConsIdent]

-- | Parse many variables
pVars :: Parser TT TTT
pVars = pMany $ pVarId

-- | parse a special symbol
sym :: (Token -> Bool) -> Parser TT TT
sym f = symbol (f . tokT)

-- | Parse anything that is in the list
exact :: [Token] -> Parser TT TT
exact = sym . (flip elem)

-- | Create a special character symbol
newT :: Char -> TT
newT = tokFromT . Special

pleaseB :: Token -> Parser TT TT
pleaseB r = (pleaseB' . exact) [r]

-- | Parse a Tok using please
pleaseB' :: Parser TT TT -> Parser TT TT
pleaseB' = (<|>) pErrN

-- | Parse a Tree tok using please
pleaseC ::Parser TT TTT ->Parser TT TTT
pleaseC = (<|>) (PError <$> pure (newT '!') <*> pErrN <*> pure [])

-- | Recover from anything
pErrN :: Parser TT TT
pErrN = recoverWith $ pure $ newT '!'

-- | Parse anything that is an error
pErr :: Parser TT TTT
pErr = PError <$> pure (newT '!')
   <*> recoverWith (sym $ not . (\x -> isComment x
                                 || CppDirective == x))
   <*> pCom

-- | Parse an ConsIdent
ppCons :: Parser TT TTT
ppCons = ppAtom [ConsIdent]

-- | Parse a keyword
pKW :: [Token] -> Parser TT TTT -> Parser TT TTT
pKW k r = KW <$> pAtom k <*> r

-- | Parse an unary operator
pOP :: [Token] -> Parser TT (Exp TT) -> Parser TT (Exp TT)
pOP op r = Op <$> exact op <*> pCom <*> r

ppOP :: [Token] -> Parser TT (Exp TT) -> Parser TT (Exp TT)
ppOP op r = Op <$> pleaseB' (sym $ flip elem op) <*> pCom <*> r

-- | Parse many comments
pCom ::Parser TT [TT]
pCom = many $ pComment

-- | Parse comment
pComment :: Parser TT TT
pComment = sym (\x -> isComment x || (CppDirective == x))

-- | Parse something thats optional
pOpt :: Parser TT TTT -> Parser TT TTT
pOpt = ((<$>) Opt) . optional

-- | Parse an atom
pAtom :: [Token] -> Parser TT TTT
pAtom b = PAtom <$> exact b <*> pCom

-- | Parse an atom using please
ppAtom :: [Token] -> Parser TT TTT
ppAtom b = pleaseC (PAtom <$> exact b <*> pCom)

-- | Parse something separated by, with optional ending
pSepBy :: Parser TT TTT -> Parser TT TTT -> Parser TT TTT
pSepBy r p = Bin <$> pMany (Bin <$> r <*> p)
         <*> pOpt r

-- | Parse a comma separator
pComma :: Parser TT TTT
pComma = pAtom [Special ',']

-- End of helper functions Parsing different parts follows

-- | Parse a Module declaration
pModule :: Parser TT (PModule TT)
pModule = PModule <$> pAtom [Reserved Module]
      <*> ppAtom [ConsIdent]
      <*> pExports
      <*> ((optional $ exact [Special '.']) *>
           (Bin <$> ppAtom [Reserved Where])
           <*> pMany pErr') <* pEmod
    where pExports = pOpt (pTup $ pSepBy pExport pComma)
          pExport = ((optional $ exact [Special '.']) *> pleaseC
                     (pVarId
                      <|> pEModule
                      <|> (Bin <$> ppQvarsym <*> (DC <$> pOpt helper))
                      <|> (Bin <$> (TC <$> pQtycon) <*> (DC <$> pOpt helper))
                     ))
          helper = pTup $  pleaseC ((pAtom [ReservedOp $ OtherOp ".."])
                                    <|> (pSepBy pQvarid pComma))
          pEmod = testNext (\r ->(not $ isJust r) ||
                            ((flip elem elems)
                             . tokT . fromJust) r)
          elems = [(Special '.'), (Special '<'), (Special '>')]
          pErr' = PError <$> pure (newT '!') <*> 
                  recoverWith (sym $ not . (\x -> isComment x
                                            ||elem x [CppDirective
                                                     , (Special '<')
                                                     , (Special '>')
                                                     , (Special '.')]))
              <*> pCom

-- | Check if next token is in given list
pTestTok :: [Token] -> Parser TT ()
pTestTok f = testNext (\r -> (not $ isJust r) || elem ((tokT . fromJust) r) f)

-- | Parse several imports
pImp :: Parser TT [PImport TT]
pImp = many (pImp'
             <* pTestTok pEol
             <* (optional $ exact [(Special '.'),(Special ';')]))
    where pEol = [(Special '<'),(Special ';'), (Special '.'), (Special '>')]
 
-- | Parse one import
-- pImp' :: Parser TT TTT
pImp' :: Parser TT (PImport TT)
pImp' = PImport  <$> pAtom [Reserved Import]
    <*> pOpt (pAtom [Reserved Qualified])
    <*> ppAtom [ConsIdent]
    <*> pOpt (pKW [Reserved As] ppCons)
    <*> (TC <$> pImpSpec)
    where pImpSpec = ((Bin <$> (pKW [Reserved Hiding] $
                                pleaseC pImpS) <*> pMany pErr)
                      <|> (Bin <$> pImpS <*> pMany pErr))
                 <|> pMany pErr
          pImpS    = DC <$> (pTup (pSepBy pExp' pComma))
          pExp'    = Bin <$> ((PAtom <$> sym (\x -> (flip elem [VarIdent, ConsIdent] x)
                                              || isOperator x) <*> many pComment)
                              <|>  ppQvarsym) <*> pOpt pImpS

-- | Parse simple types
pSType :: Parser TT TTT
pSType = PType <$> exact [Reserved Type] <*> pCom
     <*> (TC <$> ppCons) <*> pMany pQvarid
     <*> pleaseB (ReservedOp Equal) <*> pCom
     <*> (TC <$> pleaseC pType) <* pTestTok pEol
    where pEol =[ (Special '<')
                , (Special ';')
                , (Special '.')
                , (Special '>')]

-- | Parse typedeclaration
pType :: Parser TT TTT
pType = Block <$> some pAtype `BL.sepBy1` pAtom [ReservedOp RightArrow]

pSimpleType :: Parser TT TTT
pSimpleType = (Bin <$> (TC <$> ppCons) <*> pMany pQvarid)
          <|> pTup (Bin <$> (TC <$> ppCons) <*> pMany pQvarid)

-- | Parse data declarations
pSData :: Parser TT TTT
pSData = PData <$> exact [(Reserved Data)] <*> pCom
     <*> pOpt (TC <$> pContext)
     <*> (Bin <$> (TC <$> pSimpleType)   <*> pMany pErr')
     <*> (pOpt (Bin <$> pSData' <*> pMany pErr)) <* pTestTok pEol
    where pErr' = PError <$> pure (newT '!')
              <*> recoverWith (sym $ not .
                               (\x -> isComment x
                                ||(elem x [ CppDirective
                                          , (ReservedOp Equal)
                                          , (Reserved Deriving)])
                               )) <*> pCom
          pEol = [(Special ';'), (Special '.'), (Special '>')]

-- | Parse second half of the data declaration, if there is one
pSData' :: Parser TT TTT
pSData' = (PData' <$> eqW <*> pCom -- either we have standard data, or we have GADT:s
           <*> (pleaseC pConstrs
                <|> pBlockOf' (Block <$> many pGadt `BL.sepBy1` exact [Special '.']))
           <*> pOpt pDeriving)
      <|> pDeriving
    where eqW = (exact [(ReservedOp Equal),(Reserved Where)])

-- | Parse an GADT declaration
pGadt :: Parser TT TTT
pGadt = (Bin <$> (DC <$> pQtycon)
         <*> (ppOP [ReservedOp $ OtherOp "::"]
              (Bin <$> pOpt pContext <*>
               (pType <|> (pOP [Operator "!"] pAtype) <|> pErr))))
    <|>  pErr

-- | Parse a deriving
pDeriving :: Parser TT TTT
pDeriving = TC
        <$> (pKW [Reserved Deriving]
             (pleaseC $ pTup
              (Bin <$> pleaseC pQtycon
               <*> pMany (Bin <$> pComma <*> pleaseC pQtycon))
              <|> pQtycon))

pAtype :: Parser TT TTT
pAtype = pAtype'
     <|> pErr'
    where pErr' = PError <$> pure (newT '!')
              <*> recoverWith (sym $ not .
                               (\x -> isComment x
                                ||elem x [ CppDirective
                                         , (Special '(')
                                         , (Special '[')
                                         , VarIdent
                                         , ConsIdent
                                         , (Reserved Other)
                                         , (Reserved As)]
                               )) <*> pCom

pAtype' :: Parser TT TTT -- temporary
pAtype' = pQvarid
      <|> (pTup $ pMany (pTree' [(Reserved Data), (Reserved Type)] []))
      <|> (pBrack' $ pMany (pTree' [(Reserved Data), (Reserved Type)] []))

pContext :: Parser TT TTT
pContext = Context <$> pOpt pForAll
       <*> (TC <$> (pClass'
                    <|> pTup (pSepBy pClass' pComma)))
       <*> pleaseB (ReservedOp DoubleRightArrow) <*> pCom
        where pClass' :: Parser TT TTT
              pClass' = Bin <$> pQtycon
                   <*> (pleaseC pVarId
                        <|> pTup (Bin <$> pleaseC pVarId <*> pMany pAtype'))

-- | Parse for all
pForAll :: Parser TT TTT
pForAll = pKW [Reserved Forall]
          (Bin <$> pVars <*> (ppAtom [Operator "."]))

pConstrs :: Parser TT TTT
pConstrs = Bin <$> (Bin <$> pOpt pContext <*> pConstr)
       <*> pMany (pOP [ReservedOp Pipe]
                  (Bin <$> pOpt pContext <*> pleaseC pConstr))

pConstr :: Parser TT TTT
pConstr = Bin <$> pOpt pForAll
      <*> (Bin <$>
           (Bin <$> (DC <$> pAtype) <*>
            (TC <$> pMany (strictF pAtype))) <*> pOpt st)
      <|> Bin <$> lrHs <*> pMany (strictF pAtype)
      <|> pErr
    where lrHs = pOP [Operator "!"] pAtype
          st = pBrace' $ pOpt
               (Bin <$> pFielddecl
                <*> pMany (Bin <$> pComma <*> pFielddecl))

-- | Parse optional strict variables
strictF :: Parser TT TTT -> Parser TT TTT
strictF a = Bin <$> pOpt (pAtom [Operator "!"]) <*> a

pFielddecl ::Parser TT TTT
pFielddecl = Bin <$> pVars
         <*> pOpt (pOP [ReservedOp $ OtherOp "::"]
                   (pType
                    <|> (pKW [Operator "!"] pAtype)
                    <|> pErr))

-- | Exporting module
pEModule ::Parser TT TTT
pEModule = pKW [Reserved Module] (Modid <$> pleaseB' (exact [ConsIdent]) <*> pCom)

-- | Parse a Let expression
pLet :: Parser TT (Exp TT)
pLet = PLet <$> exact [Reserved Let] <*> pCom
   <*> ((pBlockOf' (Block <$> pBlocks (pTr el [(Reserved In),(ReservedOp Pipe),(ReservedOp Equal)])))
        <|> ((Expr <$> pure []) <* pTestTok pEol))
   <*>  pOpt (PAtom <$> exact [Reserved In] <*> pure [])
    where pEol = [(Special '>')]
          el = [(Reserved Data),(Reserved Type)]

-- | Parse a class decl
pClass :: Parser TT TTT
pClass = PClass <$> pAtom [Reserved Class]
     <*> (TC <$> pOpt (Bin <$> (pSContext <|> (pTup $ pSepBy pSContext pComma))
                       <*> ppAtom [ReservedOp DoubleRightArrow]))
     <*> ppAtom [ConsIdent]
     <*> ppAtom [VarIdent]
     <*> (((pMany pErr') <* pTestTok pEol) <|> pW)
        where pW = Bin <$> pAtom [Reserved Where]
               <*> pleaseC (pBlockOf $ pTree pWBlock err' atom')
              pEol = [(Special '.'), (Special '>')]
              pErr' = PError <$> pure (newT '!') <*>
                     recoverWith (sym $ not . (\x -> isComment x
                                               || elem x [CppDirective
                                                         , (Special '>')
                                                         , (Special '.')]))
                 <*> pCom
              err' = [(Reserved In)]
              atom' = [(ReservedOp Equal),(ReservedOp Pipe), (Reserved In)]

pSContext :: Parser TT TTT
pSContext = Bin <$> pAtom [ConsIdent] <*> ppAtom [VarIdent]

-- | Parse instances, no extensions are supported, but maybe multi-parameter should be supported
pInstance :: Parser TT TTT
pInstance = PInstance <$> pAtom [Reserved Instance]
        <*> (TC <$> pOpt (Bin <$> (pSContext <|> (pTup $ pSepBy pSContext pComma))
                       <*> ppAtom [ReservedOp DoubleRightArrow]))
        <*> ppAtom [ConsIdent]
        <*> pInst
        <*> (Bin <$> (pMany pErr <* pTestTok pEol) <*> pW)
        where pW = Bin <$> ppAtom [Reserved Where]
               <*> (pBlockOf $ pTree pWBlock err' atom')
              pInst = pleaseC (pAtom [ConsIdent] <|> (pTup $ pMany (pTree' [(Reserved Data), (Reserved Type)] []))
                               <|> (pBrack' $ pMany (pTree' [(Reserved Data), (Reserved Type)] [])))-- temporary..
              pEol = [(Special '.'), (Special '>'),(Special '<'), (Reserved Where)]
              err' = [(Reserved In)]
              atom' = [(ReservedOp Equal),(ReservedOp Pipe), (Reserved In)]

-- check if pEq can be used here instead problem with optional ->
pGuard :: Parser TT TTT
pGuard = PGuard
     <$> some (PGuard' <$> (exact [ReservedOp Pipe]) <*>
               -- comments are by default parsed after this
               (Expr <$> (pTr' err at))
               <*> pleaseB' (exact
                             [(ReservedOp Equal),(ReservedOp RightArrow)])
               -- comments are by default parsed after this -- this must be -> if used in case
               <*> (Expr <$> pTr' err' at'))
  where err  = [(Reserved Class),(Reserved Instance),(Reserved Data), (Reserved Type)]
        at   = [(ReservedOp RightArrow),(ReservedOp Equal), (ReservedOp Pipe)]
        err' = [(Reserved Class),(Reserved Instance),(Reserved In),(Reserved Data), (Reserved Type)]
        at'  = [(Reserved In), (ReservedOp Pipe)]

pRHS :: [Token] -> [Token] ->Parser TT TTT
pRHS err at = pGuard
          <|> pEq err at

pEq :: [Token] -> [Token] -> Parser TT TTT
pEq _ at = RHS <$> (PAtom <$> exact [ReservedOp Equal] <*> pure [])
       <*> (pTr' err ([(ReservedOp Equal), (ReservedOp Pipe)] `union` at))
  where err  = [ (Reserved In)
               , (ReservedOp Equal)
               , (Reserved Class)
               , (Reserved Instance)
               , (Reserved Data)
               , (Reserved Type)]

-- | Parse many of something
pMany ::Parser TT TTT -> Parser TT TTT
pMany r = Expr <$> many r

pDTree :: Parser TT [TTT]
pDTree = pTree (\_ _ -> pure []) err atom
    where err  = [(Reserved In)]
          atom = [(ReservedOp Equal), (ReservedOp Pipe), (Reserved In)]

-- | Parse a some of something separated by the token (Special '.')
pBlocks :: Parser TT r -> Parser TT (BL.BList r)
pBlocks p =  p `BL.sepBy1` exact [Special '.']

-- | Parse a block of some something separated by the tok (Special '.')
pBlockOf :: Parser TT [TTT] -> Parser TT TTT
pBlockOf p  = Block <$> (pBlockOf' $ pBlocks p) -- see HACK above

-- | Parse something surrounded by (Special '<') and (Special '>')
pBlockOf' :: Parser TT a -> Parser TT a
pBlockOf' p = exact [Special '<'] *> p <* exact [Special '>'] -- see HACK above

-- | Parse paren expression with comments
pTup :: Parser TT TTT -> Parser TT TTT
pTup p = Paren <$>  pAtom [Special '(']
     <*> p <*> ppAtom [Special ')']

-- | Parse a Braced expression with comments
pBrace' :: Parser TT TTT -> Parser TT TTT
pBrace' p = Paren  <$>  pAtom [Special '{']
        <*> p  <*> ppAtom [Special '}']

-- | Parse a Bracked expression with comments
pBrack' :: Parser TT TTT -> Parser TT TTT
pBrack' p = Paren  <$>  pAtom [Special '[']
        <*> p <*> ppAtom [Special ']']

-- | Parse something that can contain a data, type declaration or a class
pTree :: ([Token] ->[Token] -> Parser TT [TTT]) -> [Token] -> [Token] -> Parser TT [TTT]
pTree opt err at = ((:) <$> beginLine
                    <*> (pTypeSig
                         <|> (pTr err (at `union` [(Special ','), (ReservedOp (OtherOp "::"))]))
                         <|> ((:) <$> pAtom [Special ','] <*> pTree (\_ _ -> pure []) err at))) -- change to opt err at <|> beginLine dont forget to include type data etc in err
     <|> ((:) <$> pSType <*> pure [])
     <|> ((:) <$> pSData <*> pure [])
     <|> ((:) <$> pClass <*> pure [])
     <|> ((:) <$> pInstance <*> pure [])
     <|> opt err at
    where beginLine = (pTup' (Expr <$> pTr err at))
                  <|> (PAtom <$> sym (flip notElem $ isNoise errors) <*> pure [])
                  <|> (PError <$> pure (newT '!') <*> recoverWith
                       (sym $ flip elem $ isNoiseErr errors) <*> pure [])
          errors = [ (Reserved Class)
                   , (Reserved Instance)
                   , (ReservedOp Pipe)
                   , (ReservedOp Equal)
                   , (Reserved Let)
                   , (Reserved In)
                   , (Reserved Where)
                   , (Special '{')
                   , (Special '[')]

-- | The pWBlock describes what extra things are allowed in a where clause
pWBlock :: [Token] -> [Token] -> Parser TT [TTT]
pWBlock err at = pure []
     <|> ((:) <$> (pBrack $ Expr <$> pTr' err (at \\ [(Special ','), (ReservedOp Pipe),(ReservedOp Equal)]))
          <*> (pTr err $ at `union` [(Special ','), (ReservedOp (OtherOp "::"))]))
     <|> ((:) <$> (pBrace $ Expr <$> (pTr' err (at \\ [(Special ','),(ReservedOp Pipe),(ReservedOp Equal)])))
          <*> (pTr err $ at `union` [(Special ','), (ReservedOp (OtherOp "::"))]))


-- | Parse something not containing a Type, Data declaration or a class kw but parse a where
pTr :: [Token] -> [Token] -> Parser TT [TTT]
pTr err at
    = pure []
  <|> ((:) <$> (pTree' (noiseErr \\ [(ReservedOp Pipe),(ReservedOp Equal)]) at
                <|> pBlockOf (pTr err (at \\ [(Special ',')])))
       <*> pTr err (at \\ [(ReservedOp (OtherOp "::")),(Special ','),(ReservedOp RightArrow)]))
  <|> ((:) <$> pRHS err (at \\ [(Special ','),(ReservedOp (OtherOp "::"))]) <*> pure []) -- guard or equal
  <|> ((:) <$> (PWhere <$> exact [Reserved Where] <*> many pComment <*> pleaseC (pBlockOf $ pTree pWBlock err' atom'))
       <*> pTree (\_ _ -> pure []) err' atom')
    where err' = [(Reserved In)]
          atom' = [(ReservedOp Equal),(ReservedOp Pipe), (Reserved In)]

-- | Parse something where guards are not allowed
pTr' :: [Token] -> [Token] -> Parser TT [TTT]
pTr' err at = pure []
          <|> ((:) <$> (pTree' ([ReservedOp Pipe] `union` err) at
                        <|> (pBlockOf (pTr err (([(ReservedOp Equal), (ReservedOp Pipe)] `union` at)
                                                \\ [(ReservedOp (OtherOp "::")),(ReservedOp RightArrow)]))))
               <*> pTr' err at)
          <|> ((:) <$> (PWhere <$> exact [Reserved Where] <*> many pComment <*> pleaseC (pBlockOf $ pTree pWBlock err' atom'))
              <*> pTr' err at)
    where err' = [(Reserved In)]
          atom' = [(ReservedOp Equal),(ReservedOp Pipe), (Reserved In)]

-- | Parse a Tree' of expressions
pTree' ::[Token] -> [Token] -> Parser TT TTT
pTree' err at
    = (pTup' (Expr <$> (pTr err (at \\ [Special ',']))))
  <|> (pBrack (Expr <$> (pTr' err (at \\ [(Special ','), (ReservedOp Pipe),(ReservedOp Equal)]))))
  <|> (pBrace (Expr <$> (pTr' err (at \\ [(Special ','),(ReservedOp Pipe),(ReservedOp Equal)]))))
  <|> pLet
  <|> (PError <$>  pure (newT '!') <*> recoverWith
       (sym $ flip elem $ (isNoiseErr err)) <*> pure [])
  <|> (PAtom <$> sym (flip notElem $ (isNoise at)) <*> pure [])
      -- note that, by construction, '<' and '>' will always be matched, so
      -- we don't try to recover errors with them.

-- | Parse a typesignature 
-- not finished yet!!
pTypeSig :: Parser TT [TTT]
pTypeSig = ((:) <$> (TS <$>  exact [ReservedOp (OtherOp "::")]
                     <*> (pTr noiseErr []) <* pTestTok pEol) <*> pure [])
    where pEol = [(Special ';'), (Special '>'), (Special '<'), (Special '.'), (Special ')')]

-- | A list of keywords that usually should be an error
noiseErr :: [Token]
noiseErr = [(Reserved Class)
           , (Reserved Instance)
           , (ReservedOp Pipe)
           , (Reserved In)
           , (Reserved Data)
           , (Reserved Type)]

-- | List of things that allways should be parsed as errors
isNoiseErr :: [Token] -> [Token]
isNoiseErr r
    = [ (Reserved Module)
      , (Reserved Import)
      , (Special '}')
      , (Special ')')
      , (Special ']')] ++ r

-- | List of things that never should be parsed as an atom
isNoise :: [Token] -> [Token]
isNoise r
    = [ (Reserved Let)
      , (Reserved Class)
      , (Reserved Instance)
      , (Reserved Module)
      , (Reserved Import)
      , (Reserved Type)
      , (Reserved Data)
      , (Reserved Where)] ++ (fmap Special "()[]{}<>.") ++ r

-- | Parse an atom witout comments
pEAtom :: [Token] -> Parser TT TTT
pEAtom r = PAtom <$> exact r <*> pure []

-- | Parse paren expression with comments
pTup' :: Parser TT TTT -> Parser TT TTT
pTup' p = (Paren <$> pEAtom [Special '(']
          <*> p <*> pleaseC (pEAtom [Special ')']))

-- | Parse a Braced expression with comments
pBrace :: Parser TT TTT -> Parser TT TTT
pBrace p  = (Paren  <$>  pEAtom [Special '{']
              <*> p  <*> pleaseC (pEAtom [Special '}']))

-- | Parse a Bracked expression with comments
pBrack :: Parser TT TTT -> Parser TT TTT
pBrack p = (Paren  <$>  pEAtom [Special '[']
             <*> p <*> pleaseC (pEAtom [Special ']']))