{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Asm
Description : Tiny total AArch64 emitter for EL0 userspace tools.
Stability   : experimental

Host-side EDSL: builds the same @.s@ that @scripts/mk-userspace.sh@ +
@userspace.ld@ + @build-probe/repack.py@ consume. Covers only what the
tools use; no new instructions without a tool that needs them.

Security: operands are typed, never string-assembled. @SvcImm@ is a
@Word8@ smart constructor bounded to the existing svc set (@0x00..0x14@);
registers are bounded to @x0..x30@. The renderer is total.
-}
module Userspace.Asm (
  Reg (..),
  mkX,
  mkW,
  SvcImm,
  mkSvc,
  svcImmValue,
  U12,
  mkU12,
  u12Value,
  Cond (..),
  Instr (..),
  Builder,
  emit,
  build,
  render,
  renderInstr,
)
where

import Data.Word (Word16, Word64, Word8)

-- | AArch64 register: @x0..x30@, @w0..w30@, or @sp@.
data Reg
  = X Word8
  | W Word8
  | SP
  deriving (Eq, Show)

-- | Smart constructor for @x@ registers. @Nothing@ when out of range.
mkX :: Word8 -> Maybe Reg
mkX n
  | n <= 30 = Just (X n)
  | otherwise = Nothing

-- | Smart constructor for @w@ registers. @Nothing@ when out of range.
mkW :: Word8 -> Maybe Reg
mkW n
  | n <= 30 = Just (W n)
  | otherwise = Nothing

-- | svc immediate, bounded to the existing EL0 set (@0x00..0x14@).
newtype SvcImm = SvcImm {svcImmValue :: Word8}
  deriving (Eq, Show)

-- | Smart constructor for svc immediates. @Nothing@ when out of range.
mkSvc :: Word8 -> Maybe SvcImm
mkSvc n
  | n <= 0x14 = Just (SvcImm n)
  | otherwise = Nothing

-- | 12-bit immediate for @add@/@sub@/@cmp@/@ldr@/@strb@ offsets (0..4095).
newtype U12 = U12 {u12Value :: Word16}
  deriving (Eq, Show)

-- | Smart constructor for 12-bit immediates. @Nothing@ when out of range.
mkU12 :: Word16 -> Maybe U12
mkU12 n
  | n <= 4095 = Just (U12 n)
  | otherwise = Nothing

-- | Branch conditions used by the tools.
data Cond
  = Lo
  | Hs
  | Eq
  | Ne
  | Hi
  deriving (Eq, Show)

{- | Assembly unit. One constructor per emitted line shape, so the
renderer stays total and column-exact.
-}
data Instr
  = Comment String
  | IndentedComment String
  | Arch String
  | Text
  | Global String
  | TypeDir String String
  | Label String
  | Blank
  | DataSection
  | Align Int
  | Ascii String
  | Space Int
  | Quad Word64
  | Adrp Reg String
  | AddLo12 Reg Reg String
  | MovImm Reg Word16
  | MovChar Reg Char
  | MovHex Reg Word16
  | MovNeg Reg Word16
  | MovReg Reg Reg
  | AddReg Reg Reg Reg
  | SubReg Reg Reg Reg
  | AddImm Reg Reg U12
  | SubImm Reg Reg U12
  | LdrMem Reg Reg
  | LdrOff Reg Reg U12
  | LdrbReg Reg Reg Reg
  | StrbOff Reg Reg U12
  | StrbPost Reg Reg U12
  | StpPush Reg Reg Reg
  | LdpPop Reg Reg Reg
  | CmpImm Reg U12
  | CmpShift12 Reg U12
  | CmpReg Reg Reg
  | Cbz Reg String
  | Cbnz Reg String
  | BCond Cond String
  | B String
  | Bl String
  | Ret
  | Trail Instr String
  | LocalInstr String Instr
  | Svc SvcImm (Maybe String)
  deriving (Eq, Show)

-- | Writer of instructions. List-backed; tools emit tens of lines only.
newtype Builder = Builder {unBuilder :: [Instr]}
  deriving (Eq, Show)

instance Semigroup Builder where
  Builder a <> Builder b = Builder (a <> b)

instance Monoid Builder where
  mempty = Builder []

-- | Emit a single instruction.
emit :: Instr -> Builder
emit i = Builder [i]

-- | Run a builder to its instruction list.
build :: Builder -> [Instr]
build = unBuilder

{- | Render one register. Total: out-of-range @Word8@ cannot occur via
the smart constructors, but render defensively as @xzr@/@wzr@.
-}
renderReg :: Reg -> String
renderReg SP = "sp"
renderReg (X n)
  | n <= 30 = 'x' : show n
  | otherwise = "xzr"
renderReg (W n)
  | n <= 30 = 'w' : show n
  | otherwise = "wzr"

-- | Two uppercase hex digits (matches the checked-in @svc #0x0C@ style).
hex2 :: Word8 -> String
hex2 n = [hi, lo]
  where
    digit v
      | v < 10 = toEnum (fromEnum '0' + fromIntegral v)
      | otherwise = toEnum (fromEnum 'A' + fromIntegral v - 10)
    hi = digit (n `div` 16)
    lo = digit (n `mod` 16)

{- | Escape an ascii payload for @.ascii "..."@. Only backslash, quote,
and newline occur in the tools; anything else non-printable is octal.
-}
escapeAscii :: String -> String
escapeAscii = concatMap esc
  where
    esc '\\' = "\\\\"
    esc '"' = "\\\""
    esc '\n' = "\\n"
    esc '\0' = "\\0"
    esc c
      | c >= ' ' && c <= '~' = [c]
      | otherwise = '\\' : oct3 (fromEnum c)
    oct3 v =
      let d2 = v `div` 64
          d1 = (v `div` 8) `mod` 8
          d0 = v `mod` 8
       in [ toEnum (fromEnum '0' + d2)
          , toEnum (fromEnum '0' + d1)
          , toEnum (fromEnum '0' + d0)
          ]

-- | Minimal lowercase hex (no leading zeros) for @#0x@ immediates.
hexWord :: Word16 -> String
hexWord 0 = "0"
hexWord n = reverse (go n)
  where
    go 0 = []
    go v = digit (v `mod` 16) : go (v `div` 16)
    digit v
      | v < 10 = toEnum (fromEnum '0' + fromIntegral v)
      | otherwise = toEnum (fromEnum 'a' + fromIntegral v - 10)

-- | Render a branch condition suffix.
renderCond :: Cond -> String
renderCond Lo = "lo"
renderCond Hs = "hs"
renderCond Eq = "eq"
renderCond Ne = "ne"
renderCond Hi = "hi"

-- | Drop the 4-space instruction indent (for same-line local labels).
stripIndent :: String -> String
stripIndent (' ' : ' ' : ' ' : ' ' : rest) = rest
stripIndent s = s

-- | Render a single instruction to one line (no trailing newline).
renderInstr :: Instr -> String
renderInstr (Comment s) = "// " ++ s
renderInstr (IndentedComment s) = "    // " ++ s
renderInstr (Arch s) = ".arch " ++ s
renderInstr Text = ".text"
renderInstr (Global s) = ".global " ++ s
renderInstr (TypeDir name typ) = ".type " ++ name ++ ", " ++ typ
renderInstr (Label s) = s ++ ":"
renderInstr Blank = ""
renderInstr DataSection = "    .data"
renderInstr (Align n) = "    .align " ++ show n
renderInstr (Ascii s) = "    .ascii  \"" ++ escapeAscii s ++ "\""
renderInstr (Space n) = "    .space  " ++ show n
renderInstr (Quad n) = "    .quad   " ++ show n
renderInstr (Adrp r lbl) = "    adrp    " ++ renderReg r ++ ", " ++ lbl
renderInstr (AddLo12 rd rn lbl) =
  "    add     " ++ renderReg rd ++ ", " ++ renderReg rn ++ ", :lo12:" ++ lbl
renderInstr (MovImm r n) = "    mov     " ++ renderReg r ++ ", #" ++ show n
renderInstr (MovChar r c) = "    mov     " ++ renderReg r ++ ", #'" ++ [c] ++ "'"
renderInstr (MovHex r n) = "    mov     " ++ renderReg r ++ ", #0x" ++ hexWord n
renderInstr (MovNeg r n) = "    mov     " ++ renderReg r ++ ", #-" ++ show n
renderInstr (MovReg rd rn) = "    mov     " ++ renderReg rd ++ ", " ++ renderReg rn
renderInstr (AddReg rd rn rm) =
  "    add     " ++ renderReg rd ++ ", " ++ renderReg rn ++ ", " ++ renderReg rm
renderInstr (SubReg rd rn rm) =
  "    sub     " ++ renderReg rd ++ ", " ++ renderReg rn ++ ", " ++ renderReg rm
renderInstr (AddImm rd rn n) =
  "    add     " ++ renderReg rd ++ ", " ++ renderReg rn ++ ", #" ++ show (u12Value n)
renderInstr (SubImm rd rn n) =
  "    sub     " ++ renderReg rd ++ ", " ++ renderReg rn ++ ", #" ++ show (u12Value n)
renderInstr (LdrMem rd rn) = "    ldr     " ++ renderReg rd ++ ", [" ++ renderReg rn ++ "]"
renderInstr (LdrOff rd rn n) =
  "    ldr     " ++ renderReg rd ++ ", [" ++ renderReg rn ++ ", #" ++ show (u12Value n) ++ "]"
renderInstr (LdrbReg rd rn rm) =
  "    ldrb    " ++ renderReg rd ++ ", [" ++ renderReg rn ++ ", " ++ renderReg rm ++ "]"
renderInstr (StrbOff rd rn n) =
  "    strb    " ++ renderReg rd ++ ", [" ++ renderReg rn ++ ", #" ++ show (u12Value n) ++ "]"
renderInstr (StrbPost rd rn n) =
  "    strb    " ++ renderReg rd ++ ", [" ++ renderReg rn ++ "], #" ++ show (u12Value n)
renderInstr (StpPush ra rb rn) =
  "    stp     " ++ renderReg ra ++ ", " ++ renderReg rb ++ ", [" ++ renderReg rn ++ ", #-16]!"
renderInstr (LdpPop ra rb rn) =
  "    ldp     " ++ renderReg ra ++ ", " ++ renderReg rb ++ ", [" ++ renderReg rn ++ "], #16"
renderInstr (CmpImm rn n) = "    cmp     " ++ renderReg rn ++ ", #" ++ show (u12Value n)
-- \| Shifted compare source form (@cmp Rn, #4096#, encodable as @#1, lsl #12@).
renderInstr (CmpShift12 rn n) =
  "    cmp     " ++ renderReg rn ++ ", #" ++ show (fromIntegral (u12Value n) * 4096 :: Int)
renderInstr (CmpReg ra rb) = "    cmp     " ++ renderReg ra ++ ", " ++ renderReg rb
renderInstr (Cbz r lbl) = "    cbz     " ++ renderReg r ++ ", " ++ lbl
renderInstr (Cbnz r lbl) = "    cbnz    " ++ renderReg r ++ ", " ++ lbl
renderInstr (BCond c lbl) = "    b." ++ renderCond c ++ "    " ++ lbl
renderInstr (B lbl) = "    b       " ++ lbl
renderInstr (Bl lbl) = "    bl      " ++ lbl
renderInstr Ret = "    ret"
renderInstr (Trail i c) = padTo 36 (renderInstr i) ++ "// " ++ c
renderInstr (LocalInstr lbl i) = lbl ++ ":  " ++ stripIndent (renderInstr i)
renderInstr (Svc imm mComment) =
  let base = "    svc     #0x" ++ hex2 (svcImmValue imm)
   in case mComment of
        Nothing -> base
        Just c -> padTo 36 base ++ "// " ++ c

-- | Right-pad with spaces to a column width. Total: no truncation.
padTo :: Int -> String -> String
padTo w s
  | length s >= w = s
  | otherwise = s ++ replicate (w - length s) ' '

-- | Render a full @.s@ file. Lines joined with @\n@, trailing newline.
render :: [Instr] -> String
render is = unlines (map renderInstr is)
