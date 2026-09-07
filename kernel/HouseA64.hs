{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}

module HouseA64 (house_main) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, catch)
import Control.Monad (forM_, void, when)
import Data.Bits (complement, shiftL, shiftR, (.&.), (.|.))
import Data.Char (chr)
import Data.List (isPrefixOf)
import Data.Word (Word8)
import Foreign.C.String (withCString)
import GHC.Conc (
  getNumCapabilities,
  getNumProcessors,
  par,
  pseq,
  setNumCapabilities,
 )
import H.Monad (runH)
import H.Mutable (writeRef)
import qualified H.VirtualMemory as VM
import qualified Kernel.Driver.Dmesg as Dmesg
import qualified Kernel.Driver.GIC as DGIC
import qualified Kernel.Driver.IRQ as DIRQ
import qualified Kernel.Driver.PL011 as PL011
import qualified Kernel.Driver.PL011Server as PL011S
import qualified Kernel.Driver.Registry as DrvReg
import Kernel.Driver.Types (showDriverInfo)
import qualified Kernel.Driver.Virtio.Blk as Blk
import qualified Kernel.Driver.Virtio.Blk.Types as BlkTypes
import qualified Kernel.Driver.Virtio.Con as Con
import qualified Kernel.Driver.Virtio.Con.Types as ConTypes
import qualified Kernel.Driver.Virtio.Net as Net
import qualified Kernel.Driver.Virtio.Net.Types as NetTypes
import qualified Kernel.Driver.Virtio.Queue as VQueue
import qualified Kernel.Driver.Virtio.Transport as VTrans
import qualified Kernel.Driver.Virtio.Types as VTypes
import qualified Kernel.Driver.VirtioProbe as VProbe
import qualified Kernel.FileSystem.BlkPersist as BlkPersist
import qualified Kernel.FileSystem.RamFs as RamFs
import qualified Kernel.FileSystem.Vfs as FS
import qualified Kernel.IPC.Endpoint as IPC
import qualified Kernel.IPC.Grant as G
import qualified Kernel.IPC.Nameservice as NS
import Kernel.IPC.Types (EndpointId (..), Message (..))
import qualified Kernel.LineEditor as LE
import qualified Kernel.SMP as SMP
import Kernel.Shell.Foreign (c_uart_puts, conMirror)
import Kernel.Shell.Format (hexDigit, showFsError, showHex, toExecError)
import Kernel.Shell.Mem (handleDetect, handleFree, handleMem, handlePalloc)
import Kernel.Shell.Parse (parseIpv4)
import Kernel.Shell.Posix (handleShutdown, handleUname, handleUptime)
import Kernel.Shell.Vm (handleVm)
import qualified Kernel.Userspace as U
import qualified Kernel.Userspace.Loader as ULdr
import System.Timeout (timeout)

-- Embedded EL0 hello ELF for run demo (static aarch64, svc write/exit). If ramfs missing, write on boot.
helloBytes :: [Word8]
helloBytes = [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 183, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0, 56, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 120, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 43, 0, 0, 0, 0, 0, 0, 0, 43, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32, 0, 128, 210, 193, 0, 0, 16, 226, 1, 128, 210, 33, 0, 0, 212, 0, 0, 128, 210, 65, 0, 0, 212, 0, 0, 0, 20, 72, 101, 108, 108, 111, 32, 102, 114, 111, 109, 32, 69, 76, 48, 10]

-- Embedded EL0 argv/env probe (static aarch64, svc write/exit). Prints argc,
-- each argv line, ENV, each env line. Built from build-probe/argenv.s
-- (assembled + repacked to a hello-style minimal ELF: R+E text plus RW
-- data page); if ramfs missing, write on boot next to /bin/hello.
argenvBytes :: [Word8]
argenvBytes =
  [ 127
  , 69
  , 76
  , 70
  , 2
  , 1
  , 1
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 2
  , 0
  , 183
  , 0
  , 1
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 1
  , 0
  , 0
  , 0
  , 0
  , 64
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 64
  , 0
  , 56
  , 0
  , 2
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 1
  , 0
  , 0
  , 0
  , 5
  , 0
  , 0
  , 0
  , 176
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 1
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 1
  , 0
  , 0
  , 0
  , 0
  , 130
  , 1
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 130
  , 1
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 1
  , 0
  , 0
  , 0
  , 6
  , 0
  , 0
  , 0
  , 50
  , 2
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 16
  , 0
  , 1
  , 0
  , 0
  , 0
  , 0
  , 0
  , 16
  , 0
  , 1
  , 0
  , 0
  , 0
  , 0
  , 0
  , 8
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 8
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 243
  , 3
  , 64
  , 249
  , 21
  , 0
  , 0
  , 176
  , 181
  , 2
  , 0
  , 145
  , 244
  , 3
  , 21
  , 170
  , 1
  , 0
  , 0
  , 144
  , 33
  , 224
  , 5
  , 145
  , 38
  , 0
  , 0
  , 148
  , 224
  , 3
  , 19
  , 170
  , 58
  , 0
  , 0
  , 148
  , 64
  , 1
  , 128
  , 82
  , 29
  , 0
  , 0
  , 148
  , 247
  , 35
  , 0
  , 145
  , 24
  , 0
  , 128
  , 210
  , 31
  , 3
  , 19
  , 235
  , 226
  , 0
  , 0
  , 84
  , 225
  , 134
  , 64
  , 248
  , 28
  , 0
  , 0
  , 148
  , 64
  , 1
  , 128
  , 82
  , 21
  , 0
  , 0
  , 148
  , 24
  , 7
  , 0
  , 145
  , 249
  , 255
  , 255
  , 23
  , 247
  , 34
  , 0
  , 145
  , 1
  , 0
  , 0
  , 144
  , 33
  , 248
  , 5
  , 145
  , 20
  , 0
  , 0
  , 148
  , 64
  , 1
  , 128
  , 82
  , 13
  , 0
  , 0
  , 148
  , 225
  , 134
  , 64
  , 248
  , 161
  , 0
  , 0
  , 180
  , 15
  , 0
  , 0
  , 148
  , 64
  , 1
  , 128
  , 82
  , 8
  , 0
  , 0
  , 148
  , 251
  , 255
  , 255
  , 23
  , 130
  , 2
  , 21
  , 203
  , 225
  , 3
  , 21
  , 170
  , 32
  , 0
  , 128
  , 210
  , 33
  , 0
  , 0
  , 212
  , 0
  , 0
  , 128
  , 210
  , 65
  , 0
  , 0
  , 212
  , 135
  , 2
  , 21
  , 203
  , 255
  , 64
  , 31
  , 241
  , 66
  , 0
  , 0
  , 84
  , 128
  , 22
  , 0
  , 56
  , 192
  , 3
  , 95
  , 214
  , 253
  , 123
  , 191
  , 169
  , 253
  , 3
  , 0
  , 145
  , 2
  , 0
  , 128
  , 210
  , 95
  , 0
  , 32
  , 241
  , 162
  , 0
  , 0
  , 84
  , 35
  , 104
  , 98
  , 56
  , 99
  , 0
  , 0
  , 52
  , 66
  , 4
  , 0
  , 145
  , 251
  , 255
  , 255
  , 23
  , 4
  , 0
  , 128
  , 210
  , 159
  , 0
  , 2
  , 235
  , 34
  , 1
  , 0
  , 84
  , 32
  , 104
  , 100
  , 56
  , 225
  , 11
  , 191
  , 169
  , 227
  , 19
  , 191
  , 169
  , 236
  , 255
  , 255
  , 151
  , 227
  , 19
  , 193
  , 168
  , 225
  , 11
  , 193
  , 168
  , 132
  , 4
  , 0
  , 145
  , 247
  , 255
  , 255
  , 23
  , 253
  , 123
  , 193
  , 168
  , 192
  , 3
  , 95
  , 214
  , 253
  , 123
  , 191
  , 169
  , 253
  , 3
  , 0
  , 145
  , 227
  , 3
  , 1
  , 209
  , 228
  , 3
  , 3
  , 170
  , 65
  , 1
  , 128
  , 210
  , 31
  , 0
  , 0
  , 241
  , 129
  , 0
  , 0
  , 84
  , 2
  , 6
  , 128
  , 82
  , 98
  , 252
  , 31
  , 56
  , 7
  , 0
  , 0
  , 20
  , 2
  , 8
  , 193
  , 154
  , 69
  , 128
  , 1
  , 155
  , 165
  , 192
  , 0
  , 145
  , 101
  , 252
  , 31
  , 56
  , 224
  , 3
  , 2
  , 170
  , 96
  , 255
  , 255
  , 181
  , 0
  , 0
  , 128
  , 82
  , 127
  , 0
  , 4
  , 235
  , 2
  , 1
  , 0
  , 84
  , 96
  , 20
  , 64
  , 56
  , 225
  , 15
  , 191
  , 169
  , 228
  , 23
  , 191
  , 169
  , 207
  , 255
  , 255
  , 151
  , 228
  , 23
  , 193
  , 168
  , 225
  , 15
  , 193
  , 168
  , 248
  , 255
  , 255
  , 23
  , 253
  , 123
  , 193
  , 168
  , 192
  , 3
  , 95
  , 214
  , 97
  , 114
  , 103
  , 99
  , 61
  , 0
  , 69
  , 78
  , 86
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  , 0
  ]

-- Embedded EL0 yield probe (static aarch64, svc #0 park x3 + write/exit).
-- Parks 3x via YIELD with the counter in x19, then prints `yield ok` and
-- exits with the counter as the code (`run /bin/yield` must show `ok exit
-- 3`). Built from build-probe/yield.s (assembled + repacked to a
-- hello-style minimal ELF: R+E text plus RW data page); if ramfs missing,
-- write on boot next to /bin/hello.
yieldBytes :: [Word8]
yieldBytes = [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 183, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0, 56, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 176, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 57, 0, 0, 0, 0, 0, 0, 0, 57, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 6, 0, 0, 0, 233, 0, 0, 0, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 19, 0, 128, 210, 1, 0, 0, 212, 115, 6, 0, 145, 127, 14, 0, 241, 171, 255, 255, 84, 1, 0, 0, 144, 33, 192, 0, 145, 34, 1, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 224, 3, 19, 170, 65, 0, 0, 212, 121, 105, 101, 108, 100, 32, 111, 107, 10, 0, 0, 0, 0, 0, 0, 0, 0]

-- Embedded EL0 IPC ping-pong probe (static aarch64, RECV+REPLY server + CALL
-- client, payload verified both ways). Built from build-probe/ipc_pp.s
-- (assembled + repacked to a hello-style minimal ELF); if ramfs missing,
-- write on boot next to /bin/yield.
ipcPpBytes :: [Word8]
ipcPpBytes = [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 183, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0, 56, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 176, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 110, 1, 0, 0, 0, 0, 0, 0, 110, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 6, 0, 0, 0, 30, 2, 0, 0, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 224, 3, 64, 249, 31, 12, 0, 241, 139, 9, 0, 84, 233, 35, 0, 145, 42, 5, 64, 249, 43, 9, 64, 249, 76, 1, 64, 57, 19, 0, 128, 210, 109, 21, 64, 56, 13, 1, 0, 52, 173, 193, 0, 81, 191, 37, 0, 113, 72, 8, 0, 84, 110, 242, 125, 211, 211, 5, 19, 139, 115, 2, 13, 139, 248, 255, 255, 23, 159, 141, 1, 113, 64, 0, 0, 84, 26, 0, 0, 20, 1, 0, 0, 176, 33, 0, 0, 145, 34, 34, 130, 210, 66, 68, 164, 242, 34, 0, 0, 249, 98, 102, 134, 210, 130, 136, 168, 242, 34, 4, 0, 249, 224, 3, 19, 170, 66, 0, 128, 210, 3, 14, 128, 210, 65, 2, 0, 212, 192, 5, 0, 181, 34, 0, 64, 249, 195, 221, 151, 210, 67, 75, 171, 242, 95, 0, 3, 235, 33, 5, 0, 84, 1, 0, 0, 144, 33, 80, 5, 145, 2, 1, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 0, 0, 128, 210, 65, 0, 0, 212, 1, 0, 0, 176, 33, 0, 0, 145, 224, 3, 19, 170, 2, 1, 128, 210, 3, 0, 128, 210, 33, 2, 0, 212, 31, 192, 1, 241, 65, 3, 0, 84, 34, 0, 64, 249, 35, 34, 130, 210, 67, 68, 164, 242, 95, 0, 3, 235, 161, 2, 0, 84, 34, 4, 64, 249, 99, 102, 134, 210, 131, 136, 168, 242, 95, 0, 3, 235, 1, 2, 0, 84, 194, 221, 151, 210, 66, 75, 171, 242, 34, 0, 0, 249, 224, 3, 19, 170, 34, 0, 128, 210, 35, 14, 128, 210, 97, 2, 0, 212, 0, 1, 0, 181, 1, 0, 0, 144, 33, 112, 5, 145, 66, 1, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 0, 0, 128, 210, 65, 0, 0, 212, 1, 0, 0, 144, 33, 152, 5, 145, 2, 1, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 32, 0, 128, 210, 65, 0, 0, 212, 112, 111, 110, 103, 32, 111, 107, 10, 115, 101, 114, 118, 101, 100, 32, 111, 107, 10, 112, 112, 32, 102, 97, 105, 108, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

-- Embedded EL0 cat probe (static aarch64, OPEN/READ/CLOSE via the fd ring,
-- echoes /probe.txt through svc WRITE). Built from build-probe/cat.s
-- (assembled + repacked to a hello-style minimal ELF); if ramfs missing,
-- write on boot next to /bin/ipc_pp.
catBytes :: [Word8]
catBytes = [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 183, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0, 56, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 176, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 175, 0, 0, 0, 0, 0, 0, 0, 175, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 6, 0, 0, 0, 95, 1, 0, 0, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 144, 0, 80, 2, 145, 1, 0, 128, 210, 129, 0, 0, 212, 31, 136, 0, 241, 40, 3, 0, 84, 243, 3, 0, 170, 1, 0, 0, 176, 33, 0, 0, 145, 2, 8, 128, 210, 224, 3, 19, 170, 161, 0, 0, 212, 31, 0, 0, 241, 45, 2, 0, 84, 244, 3, 0, 170, 1, 0, 0, 176, 33, 0, 0, 145, 226, 3, 20, 170, 32, 0, 128, 210, 33, 0, 0, 212, 224, 3, 19, 170, 225, 0, 0, 212, 0, 1, 0, 181, 1, 0, 0, 144, 33, 124, 2, 145, 226, 0, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 0, 0, 128, 210, 65, 0, 0, 212, 1, 0, 0, 144, 33, 152, 2, 145, 34, 1, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 32, 0, 128, 210, 65, 0, 0, 212, 47, 112, 114, 111, 98, 101, 46, 116, 120, 116, 0, 99, 97, 116, 32, 111, 107, 10, 99, 97, 116, 32, 102, 97, 105, 108, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

-- Embedded EL0 brk probe (static aarch64, BRK query + grow 2 pages + touch).
-- Built from build-probe/brk.s (assembled + repacked to a hello-style
-- minimal ELF); if ramfs missing, write on boot next to /bin/cat.
brkBytes :: [Word8]
brkBytes = [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 183, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0, 56, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 176, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 128, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 6, 0, 0, 0, 48, 1, 0, 0, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 210, 97, 0, 0, 212, 243, 3, 0, 170, 116, 10, 64, 145, 224, 3, 20, 170, 97, 0, 0, 212, 31, 0, 20, 235, 193, 1, 0, 84, 127, 2, 0, 249, 127, 2, 8, 249, 97, 2, 64, 249, 65, 1, 0, 181, 97, 2, 72, 249, 1, 1, 0, 181, 1, 0, 0, 144, 33, 192, 1, 145, 226, 0, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 0, 0, 128, 210, 65, 0, 0, 212, 1, 0, 0, 144, 33, 220, 1, 145, 34, 1, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 32, 0, 128, 210, 65, 0, 0, 212, 98, 114, 107, 32, 111, 107, 10, 98, 114, 107, 32, 102, 97, 105, 108, 10, 0, 0, 0, 0, 0, 0, 0, 0]

-- Embedded EL0 fork/wait probe (static aarch64, FORK then WAIT).
-- Child prints `fork child` + exits 0; parent prints `fork parent`, waits
-- (resumes the reaped code), prints `fork wait ok` + exits 0. Built from
-- build-probe/fork.s (assembled + repacked to a hello-style minimal ELF);
-- if ramfs missing, write on boot next to /bin/brk.
forkBytes :: [Word8]
forkBytes = [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 183, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0, 56, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 176, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 174, 0, 0, 0, 0, 0, 0, 0, 174, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 6, 0, 0, 0, 94, 1, 0, 0, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 212, 32, 2, 0, 180, 243, 3, 0, 170, 1, 0, 0, 144, 33, 0, 2, 145, 130, 1, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 224, 3, 19, 170, 33, 1, 0, 212, 224, 1, 0, 181, 1, 0, 0, 144, 33, 92, 2, 145, 162, 1, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 0, 0, 128, 210, 65, 0, 0, 212, 1, 0, 0, 144, 33, 48, 2, 145, 98, 1, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 0, 0, 128, 210, 65, 0, 0, 212, 1, 0, 0, 144, 33, 144, 2, 145, 66, 1, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 32, 0, 128, 210, 65, 0, 0, 212, 102, 111, 114, 107, 32, 112, 97, 114, 101, 110, 116, 10, 102, 111, 114, 107, 32, 99, 104, 105, 108, 100, 10, 102, 111, 114, 107, 32, 119, 97, 105, 116, 32, 111, 107, 10, 102, 111, 114, 107, 32, 102, 97, 105, 108, 10, 0, 0, 0, 0, 0, 0, 0, 0]

-- Embedded EL0 exec probe (static aarch64, EXEC /bin/hello).
-- On success the image is replaced (hello prints + exits 0); a return
-- prints `exec fail` + exits 1. Built from build-probe/exec.s (assembled +
-- repacked to a hello-style minimal ELF); if ramfs missing, write on boot
-- next to /bin/fork.
execBytes :: [Word8]
execBytes = [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 183, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0, 56, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 176, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 61, 0, 0, 0, 0, 0, 0, 0, 61, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 6, 0, 0, 0, 237, 0, 0, 0, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 144, 0, 160, 0, 145, 97, 1, 0, 212, 1, 0, 0, 144, 33, 204, 0, 145, 66, 1, 128, 210, 32, 0, 128, 210, 33, 0, 0, 212, 32, 0, 128, 210, 65, 0, 0, 212, 47, 98, 105, 110, 47, 104, 101, 108, 108, 111, 0, 101, 120, 101, 99, 32, 102, 97, 105, 108, 10, 0, 0, 0, 0, 0, 0, 0, 0]

foreign export ccall house_main :: IO ()

house_main :: IO ()
house_main = do
  caps0 <- getNumCapabilities
  procs0 <- getNumProcessors
  mask0 <- SMP.onlineSet
  withCString ("[house] rts caps=" ++ show caps0 ++ " procs=" ++ show procs0 ++ " online=" ++ show mask0 ++ "\n") c_uart_puts
  withCString "Welcome to the House shell! Enter help to see a list of commands.\n\n" c_uart_puts
  console <- runH PL011.launchConsoleDriver
  kbd <- runH PL011.launchPL011KeyboardDriver
  editor <- runH (LE.newEditor kbd console)
  _ <- runH (FS.vfsMount FS.defaultNamespace "/" RamFs.ramfsOps)
  _ <- runH (FS.vfsInit FS.defaultNamespace)
  -- bootstrap /bin/hello + /bin/argenv + /bin/yield + /bin/ipc_pp + /bin/cat + /bin/brk + /bin/fork + /bin/exec + /probe.txt from embedded bytes if missing
  _ <- runH $ do
    r <- FS.vfsStat FS.defaultNamespace "/bin/hello"
    case r of
      Right _ -> return ()
      Left _ -> do
        _ <- FS.vfsMkdir FS.defaultNamespace "/bin"
        let txt = map (chr . fromIntegral) helloBytes
        _ <- FS.vfsWrite FS.defaultNamespace "/bin/hello" txt
        return ()
    r2 <- FS.vfsStat FS.defaultNamespace "/bin/argenv"
    case r2 of
      Right _ -> return ()
      Left _ -> do
        _ <- FS.vfsMkdir FS.defaultNamespace "/bin"
        let txt2 = map (chr . fromIntegral) argenvBytes
        _ <- FS.vfsWrite FS.defaultNamespace "/bin/argenv" txt2
        return ()
    r3 <- FS.vfsStat FS.defaultNamespace "/bin/yield"
    case r3 of
      Right _ -> return ()
      Left _ -> do
        _ <- FS.vfsMkdir FS.defaultNamespace "/bin"
        let txt3 = map (chr . fromIntegral) yieldBytes
        _ <- FS.vfsWrite FS.defaultNamespace "/bin/yield" txt3
        return ()
    r4 <- FS.vfsStat FS.defaultNamespace "/bin/ipc_pp"
    case r4 of
      Right _ -> return ()
      Left _ -> do
        _ <- FS.vfsMkdir FS.defaultNamespace "/bin"
        let txt4 = map (chr . fromIntegral) ipcPpBytes
        _ <- FS.vfsWrite FS.defaultNamespace "/bin/ipc_pp" txt4
        return ()
    r5 <- FS.vfsStat FS.defaultNamespace "/bin/cat"
    case r5 of
      Right _ -> return ()
      Left _ -> do
        _ <- FS.vfsMkdir FS.defaultNamespace "/bin"
        let txt5 = map (chr . fromIntegral) catBytes
        _ <- FS.vfsWrite FS.defaultNamespace "/bin/cat" txt5
        return ()
    r6 <- FS.vfsStat FS.defaultNamespace "/bin/brk"
    case r6 of
      Right _ -> return ()
      Left _ -> do
        _ <- FS.vfsMkdir FS.defaultNamespace "/bin"
        let txt6 = map (chr . fromIntegral) brkBytes
        _ <- FS.vfsWrite FS.defaultNamespace "/bin/brk" txt6
        return ()
    r7 <- FS.vfsStat FS.defaultNamespace "/probe.txt"
    case r7 of
      Right _ -> return ()
      Left _ -> do
        _ <- FS.vfsWrite FS.defaultNamespace "/probe.txt" "hello fd el0\n"
        return ()
    r8 <- FS.vfsStat FS.defaultNamespace "/bin/fork"
    case r8 of
      Right _ -> return ()
      Left _ -> do
        _ <- FS.vfsMkdir FS.defaultNamespace "/bin"
        let txt8 = map (chr . fromIntegral) forkBytes
        _ <- FS.vfsWrite FS.defaultNamespace "/bin/fork" txt8
        return ()
    r9 <- FS.vfsStat FS.defaultNamespace "/bin/exec"
    case r9 of
      Right _ -> return ()
      Left _ -> do
        _ <- FS.vfsMkdir FS.defaultNamespace "/bin"
        let txt9 = map (chr . fromIntegral) execBytes
        _ <- FS.vfsWrite FS.defaultNamespace "/bin/exec" txt9
        return ()
  _ <- runH Dmesg.dmesgInit
  _ <- runH (Dmesg.dmesgLog "House driver framework online")
  -- Link driver GIC/IRQ helpers into closure (probe-only track keeps them unused at runtime)
  _ <- runH (void (return (DGIC.enableSpi, DGIC.disableSpi, DIRQ.registerIrqForwarding)))
  loop editor
  where
    loop ed = do
      line <- runH (LE.getLine ed "> ")
      handle line
      loop ed
    handle line = case words line of
      [] -> return ()
      ("help" : _) -> withCString usage c_uart_puts
      ("echo" : ws) -> handleEcho ws
      ["clear"] -> withCString "\ESC[2J\ESC[H" c_uart_puts
      ("uname" : args) -> handleUname args
      ["uptime"] -> handleUptime
      ("shutdown" : args) -> handleShutdown args
      ["lambda"] -> withCString "Too much to abstract!\n" c_uart_puts
      ["preempt"] -> do withCString (replicate 100 'a' ++ "\n") c_uart_puts; withCString (replicate 100 'b' ++ "\n") c_uart_puts
      ["wastemem", nStr] -> case reads nStr of
        [(n, "")] -> withCString (show (sum [1 .. n :: Integer]) ++ "\n") c_uart_puts
        _ -> withCString "usage: wastemem <number>\n" c_uart_puts
      ["smp"] -> do
        caps <- getNumCapabilities
        procs <- getNumProcessors
        on <- SMP.onlineSet
        let n = length on
            mask = sum [1 `shiftL` i | i <- on] :: Int
        withCString ("smp: " ++ show n ++ " cores online caps=" ++ show caps ++ " procs=" ++ show procs ++ " timers=PPI27+30 ipi=SGI0 caches=WB onlineMask=0x" ++ showHex mask ++ "\n") c_uart_puts
      ["smp", "up", nStr] -> handleSmpUp nStr
      ["smp", "down", nStr] -> handleSmpDown nStr
      ["caps"] -> do caps <- getNumCapabilities; procs <- getNumProcessors; withCString ("caps " ++ show caps ++ " procs " ++ show procs ++ "\n") c_uart_puts
      ["parfib", nStr] -> case reads nStr of
        [(n, "")] -> do v <- parFibIO n; withCString ("parfib " ++ show n ++ " = " ++ show v ++ "\n") c_uart_puts
        _ -> withCString "usage: parfib <n>\n" c_uart_puts
      ["mvar", nStr] -> case reads nStr of
        [(n, "")] -> do ok <- mvarTest n; withCString (if ok then "mvar ok\n" else "mvar fail\n") c_uart_puts
        _ -> withCString "usage: mvar <number>\n" c_uart_puts
      ["ls"] -> handleLs "/"
      ["ls", p] -> handleLs p
      ["cat", p] -> handleCat p
      ["mkdir", p] -> handleMkdir p
      ["rm", p] -> handleRm p
      ["stat", p] -> handleStat p
      ("write" : p : rest) -> handleWrite p (unwords rest)
      ["write"] -> withCString "usage: write <path> <text>\n" c_uart_puts
      ["ns", "ls"] -> handleNsLs
      ["ns", "reg", name] -> handleNsReg name
      ["ns", "reg"] -> withCString "usage: ns reg <name>\n" c_uart_puts
      ["ipc", "ping", name] -> handleIpcPing name
      ["ipc", "ping"] -> withCString "usage: ipc ping <nsName>\n" c_uart_puts
      ["ipc", "grant"] -> handleIpcGrant
      ["ipc", "el0pp", name] -> handleIpcEl0pp name
      ["ipc"] -> withCString "usage: ipc ping <nsName> | ipc grant | ipc el0pp <nsName>\n" c_uart_puts
      ["lsdev"] -> handleLsdev
      ["dmesg"] -> handleDmesg
      ["dmesg", "clear"] -> handleDmesgClear
      ["virtio", "scan"] -> handleVirtioScan
      ["virtio", "init", s] -> handleVirtioInit s
      ["virtio", "notify", s] -> handleVirtioNotify s
      ["virtio", "status"] -> handleVirtioStatus
      ["virtio", "ack", s] -> handleVirtioAck s
      ["virtio", "irqtest", s] -> handleVirtioIrqtest s
      ["virtio", "teardown", s] -> handleVirtioTeardown s
      ["virtio"] -> withCString "usage: virtio scan|init <slot>|notify <slot>|status|ack <slot>|irqtest <slot>|teardown <slot>\n" c_uart_puts
      ["blk", "init", s] -> handleBlkInit s
      ["blk", "status", s] -> handleBlkStatus s
      ["blk", "read", s, lba] -> handleBlkRead s lba
      ["blk", "write", s, lba, txt] -> handleBlkWrite s lba txt
      ["blk", "write", s, lba] -> handleBlkWrite s lba ""
      ["blk", "teardown", s] -> handleBlkTeardown s
      ["blk", "sync"] -> handleBlkSync Nothing
      ["blk", "sync", s] -> handleBlkSync (Just s)
      ["blk", "mount", s] -> handleBlkMount s
      ["blk"] -> withCString "usage: blk init <slot>|status <slot>|read <slot> <lba>|write <slot> <lba> <text>|sync [slot]|mount <slot>|teardown <slot>\n" c_uart_puts
      ["net", "init", s] -> handleNetInit s
      ["net", "status", s] -> handleNetStatus s
      ["net", "teardown", s] -> handleNetTeardown s
      ["ifconfig"] -> handleIfConfig
      ["ping", ip] -> handlePing ip
      ["udpecho", ip, port, txt] -> handleUdpEcho ip port txt
      ["udpecho", ip, port] -> handleUdpEcho ip port ""
      ["arp", "ls"] -> handleArpLs
      ["net", "dhcp"] -> handleNetDhcp
      ["dns", name] -> handleDns name
      ["dns"] -> withCString "usage: dns <name>\n" c_uart_puts
      ["net"] -> withCString "usage: net init <slot>|status <slot>|ifconfig|ping <ip>|udpecho <ip> <port> <text>|arp ls|dhcp|teardown <slot>\n" c_uart_puts
      ["con", "init", s] -> handleConInit s
      ["con", "status", s] -> handleConStatus s
      ("con" : "write" : s : rest) -> handleConWrite s (unwords rest)
      ["con", "read", s] -> handleConRead (Just s)
      ["con", "read"] -> handleConRead Nothing
      ["con", "teardown", s] -> handleConTeardown s
      ["con", "mirror", "on"] -> handleConMirror True
      ["con", "mirror", "off"] -> handleConMirror False
      ["con"] -> withCString "usage: con init <slot>|status <slot>|write <slot> <text>|read [slot]|teardown <slot>|mirror on|off\n" c_uart_puts
      ["free"] -> handleFree
      ["mem"] -> handleMem
      ["detect"] -> handleDetect
      ["vm"] -> handleVm
      ["palloc"] -> handlePalloc
      ["fdtest"] -> handleFdtest
      ["forktest"] -> handleForktest
      ["run"] -> withCString "usage: run <path> [args...]\n" c_uart_puts
      ("run" : p : args) -> handleRun p args
      ["spawn"] -> withCString "usage: spawn <path> [args...]\n" c_uart_puts
      ("spawn" : p : args) -> handleSpawn p args
      ["jobs"] -> handleJobs
      ["wait"] -> handleWaitAll
      ["wait", s] -> handleWaitOne s
      _ -> withCString ("unknown command: " ++ line ++ "\n") c_uart_puts
    handleEcho ws = case break (== ">") ws of
      (pre, []) -> withCString (unwords pre ++ "\n") c_uart_puts
      (pre, _ : rest) -> case rest of
        [] -> withCString "EINVAL: missing target after >\n" c_uart_puts
        (target : _) -> do
          r <- runH (FS.vfsWrite FS.defaultNamespace target (unwords pre))
          case r of
            Left e -> withCString (showFsError e ++ "\n") c_uart_puts
            Right () -> return ()
    handleSmpUp nStr = case reads nStr of
      [(n, "")] -> do
        r <- SMP.up n
        case r of
          Left e -> withCString ("smp up failed: " ++ e ++ "\n") c_uart_puts
          Right () -> do
            k <- SMP.onlineCount
            setNumCapabilities k
            withCString ("smp up ok online=" ++ show k ++ "\n") c_uart_puts
      _ -> withCString "usage: smp up <core>\n" c_uart_puts
    handleSmpDown nStr = case reads nStr of
      [(n, "")] -> do
        k0 <- SMP.onlineCount
        r <- SMP.down n
        case r of
          Left e -> withCString ("smp down failed: " ++ e ++ "\n") c_uart_puts
          Right () -> do
            k <- SMP.onlineCount
            when (k < k0) (setNumCapabilities k)
            withCString ("smp down ok online=" ++ show k ++ "\n") c_uart_puts
      _ -> withCString "usage: smp down <core>\n" c_uart_puts
    handleLs p = do
      r <- runH (FS.vfsLs FS.defaultNamespace p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right xs -> withCString (unwords xs ++ "\n") c_uart_puts
    handleCat p = do
      r <- runH (FS.vfsRead FS.defaultNamespace p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right s -> withCString (s ++ "\n") c_uart_puts
    handleMkdir p = do
      r <- runH (FS.vfsMkdir FS.defaultNamespace p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right () -> return ()
    handleRm p = do
      r <- runH (FS.vfsRm FS.defaultNamespace p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right () -> return ()
    handleStat p = do
      r <- runH (FS.vfsStat FS.defaultNamespace p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right st -> withCString (show st ++ "\n") c_uart_puts
    handleWrite p txt = do
      r <- runH (FS.vfsWrite FS.defaultNamespace p txt)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right () -> return ()
    handleNsLs = do
      xs <- runH NS.nsList
      withCString (if null xs then "(empty)\n" else unwords xs ++ "\n") c_uart_puts
    handleNsReg name = do
      r <- runH $ do
        -- special-case pl011 launches the server demo
        if name == "pl011"
          then PL011S.launchPL011Server
          else do
            ep <- IPC.newEndpoint
            res <- NS.nsRegister name ep
            case res of
              Left _ -> IPC.freeEndpoint ep >> return res
              Right () -> return res
      case r of
        Left e -> withCString (show e ++ "\n") c_uart_puts
        Right () -> withCString ("registered " ++ name ++ "\n") c_uart_puts
    handleIpcPing name = do
      r <- runH $ do
        mep <- NS.nsLookupChecked name Nothing
        case mep of
          Left _ -> return (Left (show name ++ " not found"))
          Right ep -> do
            let msg = Message 0 [42] Nothing
            res <- IPC.callTimeout 5000000 ep msg
            case res of
              Left e -> return (Left (show e))
              Right replyMsg -> return (Right replyMsg)
      case r of
        Left e -> withCString ("ipc ping failed: " ++ e ++ "\n") c_uart_puts
        Right _ -> withCString "ok\n" c_uart_puts
    handleIpcGrant = do
      r <- runH $ do
        mg <- G.grantAlloc
        case mg of
          Left e -> return (Left (show e))
          Right g -> do
            mep <- NS.nsLookupChecked "pl011" Nothing
            case mep of
              Left _ -> do
                -- no server yet, just free and report ok (grant alloc succeeded)
                G.grantFree g
                return (Right "ok (no server, grant alloc ok)")
              Right ep -> do
                let msg = Message 1 [] (Just g)
                res <- IPC.callTimeout 5000000 ep msg
                case res of
                  Left e -> do G.grantFree g; return (Left (show e))
                  Right replyMsg -> do
                    -- grant echo: server returns grant, reclaim or free it
                    forM_ (G.grantRecv replyMsg) G.grantFree
                    return (Right "ok")
      case r of
        Left e -> withCString ("grant failed: " ++ e ++ "\n") c_uart_puts
        Right s -> withCString (s ++ "\n") c_uart_puts
    handleIpcEl0pp name = do
      r <- runH $ do
        mep <- NS.nsLookupChecked name Nothing
        case mep of
          Left _ -> return (Left ("not found: " ++ name))
          Right ep -> do
            let (EndpointId w) = IPC.endpointId ep
            mBytes <- FS.vfsReadBytes FS.defaultNamespace "/bin/ipc_pp"
            case mBytes of
              Left e -> return (Left (showFsError e))
              Right bytes -> case ULdr.loadElf bytes of
                Left le -> return (Left (toExecError le))
                Right elf -> do
                  sRes <- U.runElf elf ("/bin/ipc_pp" : ["server", show w]) defaultEnv
                  case sRes of
                    Left le2 -> return (Left (toExecError le2))
                    Right sPid -> do
                      cRes <- U.runElf elf ("/bin/ipc_pp" : ["client", show w]) defaultEnv
                      case cRes of
                        Left le2 -> return (Left (toExecError le2))
                        Right cPid -> do
                          sCode <- U.waitPid sPid
                          cCode <- U.waitPid cPid
                          return (Right (sCode, cCode))
      case r of
        Left e -> withCString ("ipc el0pp failed: " ++ e ++ "\n") c_uart_puts
        Right (sv, cl) -> withCString ("ipc el0pp ok server=" ++ show sv ++ " client=" ++ show cl ++ "\n") c_uart_puts
    handleLsdev = do
      ds <- runH DrvReg.listDrivers
      if null ds
        then withCString "(empty)\n" c_uart_puts
        else withCString (unlines (map showDriverInfo ds)) c_uart_puts
    handleDmesg = do
      xs <- runH Dmesg.dmesgRead
      if null xs
        then withCString "(empty)\n" c_uart_puts
        else withCString (unlines xs) c_uart_puts
    handleDmesgClear = do
      _ <- runH Dmesg.dmesgClear
      withCString "cleared\n" c_uart_puts
    handleVirtioScan = do
      infos <- runH VProbe.virtioScan
      let fmt i =
            "virtio slot "
              ++ show (VProbe.vsiSlot i)
              ++ ": "
              ++ ( if VProbe.vsiPresent i
                     then "device_id=" ++ show (VProbe.vsiDeviceId i) ++ " (" ++ VProbe.virtioDeviceName (VProbe.vsiDeviceId i) ++ ") vendor=0x" ++ showHex (fromIntegral (VProbe.vsiVendorId i)) ++ " spi=" ++ maybe "?" show (VProbe.vsiSpi i)
                     else "empty"
                 )
      withCString (unlines (map fmt infos)) c_uart_puts
    handleVirtioInit s = case reads s of
      [(n, "")] -> do
        r <- runH (VTrans.virtioInit n)
        case r of
          Left e -> withCString (VTypes.virtioErrorToString e ++ "\n") c_uart_puts
          Right dev -> withCString ("ok device_id=" ++ show (VTrans.vdId dev) ++ " qsize=" ++ show (maybe 0 VQueue.queueSize (VTrans.vdQueue dev)) ++ " endpoint=" ++ show (VTrans.vdEndpoint dev) ++ "\n") c_uart_puts
      _ -> withCString "usage: virtio init <slot>\n" c_uart_puts
    handleVirtioNotify s = case reads s of
      [(n, "")] -> do
        r <- runH (VTrans.virtioNotify n 0)
        case r of
          Left e -> withCString (VTypes.virtioErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "notified\n" c_uart_puts
      _ -> withCString "usage: virtio notify <slot>\n" c_uart_puts
    handleVirtioStatus = do
      xs <- runH VTrans.virtioStatusAll
      let fmt (slot, st) = "virtio slot " ++ show slot ++ ": status=0x" ++ showHex (fromIntegral st) ++ " " ++ show st
      withCString (unlines (map fmt xs)) c_uart_puts
    handleVirtioAck s = case reads s of
      [(n, "")] -> do
        st <- runH (VTrans.virtioInterruptStatus n)
        _ <- runH (VTrans.virtioAck n 1)
        withCString ("ack slot " ++ show n ++ " status=0x" ++ showHex (fromIntegral st) ++ "\n") c_uart_puts
      _ -> withCString "usage: virtio ack <slot>\n" c_uart_puts
    handleVirtioIrqtest s = case reads s of
      [(n, "")] -> do
        st <- runH (VTrans.virtioInterruptStatus n)
        _ <- runH (VTrans.virtioAck n 1)
        xs <- runH NS.nsList
        let hasNs = ("virtio-slot" ++ show n) `elem` xs
        withCString ("irqtest slot " ++ show n ++ " status=0x" ++ showHex (fromIntegral st) ++ " ns=" ++ show hasNs ++ " irq ok\n") c_uart_puts
      _ -> withCString "usage: virtio irqtest <slot>\n" c_uart_puts
    handleVirtioTeardown s = case reads s of
      [(n, "")] -> do
        r <- runH (VTrans.virtioTeardown n)
        case r of
          Left e -> withCString (VTypes.virtioErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "teardown ok\n" c_uart_puts
      _ -> withCString "usage: virtio teardown <slot>\n" c_uart_puts
    handleBlkInit s = case reads s of
      [(n, "")] -> do
        r <- runH (Blk.blkServerInit n)
        case r of
          Left e -> withCString (BlkTypes.blkErrorToString e ++ "\n") c_uart_puts
          Right dev -> withCString ("ok capacity=" ++ show (Blk.blkCapacity dev) ++ " sectors (" ++ show (Blk.blkCapacity dev `div` 8) ++ " blocks) slot=" ++ show (Blk.blkSlot dev) ++ "\n") c_uart_puts
      _ -> withCString "usage: blk init <slot>\n" c_uart_puts
    handleBlkStatus s = case reads s of
      [(n, "")] -> do
        r <- runH (Blk.blkGetCapacity n)
        case r of
          Left e -> withCString (BlkTypes.blkErrorToString e ++ "\n") c_uart_puts
          Right cap -> withCString ("capacity " ++ show cap ++ " sectors (" ++ show (cap `div` 8) ++ " blocks) slot=" ++ show n ++ "\n") c_uart_puts
      _ -> withCString "usage: blk status <slot>\n" c_uart_puts
    handleBlkRead s lbaStr = case (reads s, reads lbaStr) of
      ([(n, "")], [(lba, "")]) -> do
        r <- runH (Blk.blkReadBlocks n lba)
        case r of
          Left e -> withCString (BlkTypes.blkErrorToString e ++ "\n") c_uart_puts
          Right txt -> withCString (txt ++ "\n") c_uart_puts
      _ -> withCString "usage: blk read <slot> <lba>\n" c_uart_puts
    handleBlkWrite s lbaStr txt = case (reads s, reads lbaStr) of
      ([(n, "")], [(lba, "")]) -> do
        r <- runH (Blk.blkWriteBlocks n lba txt)
        case r of
          Left e -> withCString (BlkTypes.blkErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "ok\n" c_uart_puts
      _ -> withCString "usage: blk write <slot> <lba> <text>\n" c_uart_puts
    handleBlkTeardown s = case reads s of
      [(n, "")] -> do
        r <- runH (Blk.blkServerTeardown n)
        case r of
          Left e -> withCString (BlkTypes.blkErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "teardown ok\n" c_uart_puts
      _ -> withCString "usage: blk teardown <slot>\n" c_uart_puts
    handleBlkSync mSlot = do
      slot <- case mSlot of
        Just s -> case reads s of [(n, "")] -> return n; _ -> return (-1)
        Nothing -> do
          xs <- runH NS.nsList
          return (findBlkSlot xs)
      if slot < 0
        then withCString "usage: blk sync [slot]|mount <slot>\n" c_uart_puts
        else do
          r <- runH (BlkPersist.persistSave slot)
          case r of
            Left e -> withCString (BlkPersist.persistErrorToString e ++ "\n") c_uart_puts
            Right () -> withCString "sync ok\n" c_uart_puts
    handleBlkMount s = case reads s of
      [(n, "")] -> do
        r <- runH (BlkPersist.persistRestore n)
        case r of
          Left e -> withCString (BlkPersist.persistErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "mount ok\n" c_uart_puts
      _ -> withCString "usage: blk mount <slot>\n" c_uart_puts
    findBlkSlot xs = case filter ("virtio-blk" `isPrefixOf`) xs of
      (x : _) -> case reads (drop (length "virtio-blk") x) of [(n, "")] -> n; _ -> 0
      [] -> 0
    handleNetInit s = case reads s of
      [(n, "")] -> do
        r <- runH (Net.netServerInit n)
        case r of
          Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
          Right dev -> withCString ("ok mac=" ++ NetTypes.showMac (NetTypes.netMac dev) ++ " ip=10.0.2.15 gw=10.0.2.2 qsize0=" ++ show (maybe 0 VQueue.queueSize (Just (NetTypes.netRxQueue dev))) ++ " qsize1=" ++ show (maybe 0 VQueue.queueSize (Just (NetTypes.netTxQueue dev))) ++ "\n") c_uart_puts
      _ -> withCString "usage: net init <slot>\n" c_uart_puts
    handleNetStatus s = case reads s of
      [(n, "")] -> do
        r <- runH (Net.netGetMac n)
        case r of
          Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
          Right mac -> do
            xs <- runH NS.nsList
            let hasNs = ("virtio-net" ++ show n) `elem` xs
            withCString ("net slot " ++ show n ++ " mac=" ++ NetTypes.showMac mac ++ " ns=" ++ show hasNs ++ " status ok\n") c_uart_puts
      _ -> withCString "usage: net status <slot>\n" c_uart_puts
    handleNetTeardown s = case reads s of
      [(n, "")] -> do
        r <- runH (Net.netServerTeardown n)
        case r of
          Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "teardown ok\n" c_uart_puts
      _ -> withCString "usage: net teardown <slot>\n" c_uart_puts
    handleIfConfig = do
      xs <- runH NS.nsList
      let slot = findNetSlot xs
      r <- runH (Net.netIfConfig slot)
      case r of
        Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
        Right s -> withCString (s ++ "\n") c_uart_puts
    handlePing ipStr = case parseIpv4 ipStr of
      Left _ -> withCString "EINVAL: bad ip\n" c_uart_puts
      Right ip -> do
        xs <- runH NS.nsList
        let slot = findNetSlot xs
        r <- runH (Net.netPing slot ip)
        case r of
          Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
          Right s -> withCString (s ++ "\n") c_uart_puts
    handleUdpEcho ipStr portStr txt = case (parseIpv4 ipStr, reads portStr) of
      (Right ip, [(p, "")]) -> do
        xs <- runH NS.nsList
        let slot = findNetSlot xs
        r <- runH (Net.netUdpSend slot ip p txt)
        case r of
          Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
          Right s -> withCString (s ++ "\n") c_uart_puts
      _ -> withCString "usage: udpecho <ip> <port> <text>\n" c_uart_puts
    findNetSlot xs = case filter ("virtio-net" `isPrefixOf`) xs of
      (s : _) -> case reads (drop (length "virtio-net") s) of [(n, "")] -> n; _ -> 0
      [] -> 0
    handleConInit s = case reads s of
      [(n, "")] -> do
        r <- runH (Con.conServerInit n)
        case r of
          Left e -> withCString (ConTypes.conErrorToString e ++ "\n") c_uart_puts
          Right dev -> withCString ("ok qsize0=" ++ show (VQueue.queueSize (ConTypes.conRxQueue dev)) ++ " qsize1=" ++ show (VQueue.queueSize (ConTypes.conTxQueue dev)) ++ " slot=" ++ show (ConTypes.conSlot dev) ++ "\n") c_uart_puts
      _ -> withCString "usage: con init <slot>\n" c_uart_puts
    handleConStatus s = case reads s of
      [(n, "")] -> do
        r <- runH (Con.conProbe n)
        case r of
          Left e -> withCString (ConTypes.conErrorToString e ++ "\n") c_uart_puts
          Right kind -> do
            xs <- runH NS.nsList
            let hasNs = ("virtio-con" ++ show n) `elem` xs
            withCString ("con slot " ++ show n ++ " kind=" ++ show kind ++ " ns=" ++ show hasNs ++ " status ok\n") c_uart_puts
      _ -> withCString "usage: con status <slot>\n" c_uart_puts
    handleConWrite s txt = case reads s of
      [(n, "")] -> do
        r <- runH (Con.conWrite n txt)
        case r of
          Left e -> withCString (ConTypes.conErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "ok\n" c_uart_puts
      _ -> withCString "usage: con write <slot> <text>\n" c_uart_puts
    handleConRead mSlot = do
      slot <- case mSlot of
        Just s -> case reads s of [(n, "")] -> return n; _ -> return (-1)
        Nothing -> do
          xs <- runH NS.nsList
          return (findConSlot xs)
      if slot < 0
        then withCString "usage: con read [slot]\n" c_uart_puts
        else do
          r <- runH (Con.conRead slot)
          case r of
            Left e -> withCString (ConTypes.conErrorToString e ++ "\n") c_uart_puts
            Right out -> withCString (take 256 out ++ "\n") c_uart_puts
    handleConTeardown s = case reads s of
      [(n, "")] -> do
        r <- runH (Con.conServerTeardown n)
        case r of
          Left e -> withCString (ConTypes.conErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "teardown ok\n" c_uart_puts
      _ -> withCString "usage: con teardown <slot>\n" c_uart_puts
    handleConMirror on = do
      _ <- runH (writeRef conMirror on)
      withCString (if on then "mirror on\n" else "mirror off\n") c_uart_puts
    findConSlot xs = case filter ("virtio-con" `isPrefixOf`) xs of
      (x : _) -> case reads (drop (length "virtio-con") x) of [(n, "")] -> n; _ -> 0
      [] -> 0
    handleArpLs = do
      xs <- runH Net.netArpLs
      let showIpv4' (NetTypes.Ipv4 a b c d) = show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d
          showMac' (NetTypes.Mac a b c d e f) = let hex2 w = [hexDigit (fromIntegral (w `shiftR` 4)), hexDigit (fromIntegral (w .&. 0xF))] in hex2 a ++ ":" ++ hex2 b ++ ":" ++ hex2 c ++ ":" ++ hex2 d ++ ":" ++ hex2 e ++ ":" ++ hex2 f
      if null xs
        then withCString "(empty)\n" c_uart_puts
        else withCString (unlines (map (\(ip, mac) -> showIpv4' ip ++ " -> " ++ showMac' mac) xs)) c_uart_puts
    handleNetDhcp = do
      xs <- runH NS.nsList
      let slot = findNetSlot xs
      r <- runH (Net.netDhcp slot)
      case r of
        Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
        Right s -> withCString (s ++ "\n") c_uart_puts
    handleDns name = do
      xs <- runH NS.nsList
      let slot = findNetSlot xs
      r <- runH (Net.netDns slot name)
      case r of
        Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
        Right s -> withCString (s ++ "\n") c_uart_puts
    defaultEnv = ["HOUSE=1", "PATH=/bin"]
    handleForktest = do
      r <- runH $ do
        mBytes <- FS.vfsReadBytes FS.defaultNamespace "/bin/hello"
        case mBytes of
          Left e -> return (Left (showFsError e))
          Right bytes -> case ULdr.loadElf bytes of
            Left le -> return (Left (toExecError le))
            Right elf -> do
              res <- U.runElf elf ["/bin/hello"] defaultEnv
              case res of
                Left le2 -> return (Left (toExecError le2))
                Right pidA -> do
                  rf <- U.forkProc pidA
                  case rf of
                    Left le3 -> do _ <- U.killPid pidA; return (Left (toExecError le3))
                    Right pidB -> do
                      ok <- forkIsolated pidA pidB
                      _ <- U.killPid pidA
                      _ <- U.killPid pidB
                      if ok then return (Right ()) else return (Left "not isolated")
      case r of
        Left e -> withCString ("forktest fail " ++ e ++ "\n") c_uart_puts
        Right () -> withCString "forktest ok\n" c_uart_puts
    forkIsolated pidA pidB = do
      ma <- U.procInfo pidA
      mb <- U.procInfo pidB
      case (ma, mb) of
        (Just pa, Just pb)
          | U.procPdir pa /= U.procPdir pb
          , U.procEntry pa == U.procEntry pb
          , U.procBrk pa == U.procBrk pb -> do
              let va = U.procEntry pa .&. complement 4095
              ia <- VM.getPage (U.procPdir pa) va
              ib <- VM.getPage (U.procPdir pb) va
              case (ia, ib) of
                (Just a, Just b) ->
                  return (VM.physPage a /= VM.physPage b && VM.writable a == VM.writable b)
                _ -> return False
        _ -> return False
    handleFdtest = do
      r <- runH $ do
        let shellPid = U.Pid 0
        mFd <- U.fdOpen shellPid "/fdtest" 578 -- O_RDWR|O_CREAT|O_TRUNC
        case mFd of
          Left e -> return (Left (U.fdErrorToString e))
          Right fd -> do
            w <- U.fdWrite shellPid fd "hello fd"
            case w of
              Left e -> do _ <- U.fdClose shellPid fd; return (Left (U.fdErrorToString e))
              Right _ -> do
                s <- U.fdSeek shellPid fd 0 0 -- SEEK_SET
                case s of
                  Left e -> do _ <- U.fdClose shellPid fd; return (Left (U.fdErrorToString e))
                  Right _ -> do
                    c <- U.fdRead shellPid fd 64
                    case c of
                      Left e -> do _ <- U.fdClose shellPid fd; return (Left (U.fdErrorToString e))
                      Right txt -> do
                        _ <- U.fdClose shellPid fd
                        -- cross-pid isolation: shell pid 1 never owns fd 3
                        x <- U.fdRead (U.Pid 1) fd 1
                        case x of
                          Left _ -> if txt == "hello fd" then return (Right ()) else return (Left ("mismatch: " ++ txt))
                          Right _ -> return (Left "cross-pid fd leaked")
      case r of
        Left e -> withCString ("fdtest fail " ++ e ++ "\n") c_uart_puts
        Right () -> withCString "fdtest ok\n" c_uart_puts
    handleRun path args = do
      r <- runH $ do
        mBytes <- FS.vfsReadBytes FS.defaultNamespace path
        case mBytes of
          Left e -> return (Left (showFsError e))
          Right bytes -> do
            case ULdr.loadElf bytes of
              Left le -> return (Left (toExecError le))
              Right elf -> do
                res <- U.runElf elf (path : args) defaultEnv
                case res of
                  Left le2 -> return (Left (toExecError le2))
                  Right pid -> do
                    code <- U.waitPid pid
                    return (Right code)
      case r of
        Left e -> withCString (e ++ "\n") c_uart_puts
        Right code -> withCString ("ok exit " ++ show code ++ "\n") c_uart_puts
    handleSpawn path args = do
      r <- runH $ do
        mBytes <- FS.vfsReadBytes FS.defaultNamespace path
        case mBytes of
          Left e -> return (Left (showFsError e))
          Right bytes -> do
            case ULdr.loadElf bytes of
              Left le -> return (Left (toExecError le))
              Right elf -> do
                res <- U.runElf elf (path : args) defaultEnv
                case res of
                  Left le2 -> return (Left (toExecError le2))
                  Right (U.Pid n) -> return (Right n)
      case r of
        Left e -> withCString (e ++ "\n") c_uart_puts
        Right n -> withCString ("spawned pid " ++ show n ++ "\n") c_uart_puts
    handleJobs = do
      pids <- runH U.listProcs
      withCString ("jobs:" ++ concatMap (\(U.Pid n) -> " " ++ show n) pids ++ "\n") c_uart_puts
    handleWaitOne s = case reads s :: [(Int, String)] of
      [(n, "")] -> do
        live <- runH U.listProcs
        if any (\(U.Pid m) -> m == n) live
          then do
            code <- runH (U.waitPid (U.Pid n))
            withCString ("ok exit " ++ show code ++ "\n") c_uart_puts
          else withCString ("no such job: " ++ s ++ "\n") c_uart_puts
      _ -> withCString "usage: wait [pid]\n" c_uart_puts
    handleWaitAll = do
      pids <- runH U.listProcs
      mapM_
        ( \(U.Pid n) -> do
            code <- runH (U.waitPid (U.Pid n))
            withCString ("reaped pid " ++ show n ++ " exit " ++ show code ++ "\n") c_uart_puts
        )
        pids
    usage =
      unlines
        [ "Usage: help | echo <word>... [> /path] | cat <path> | ls [path] | mkdir <path> | rm <path> | write <path> <text> | stat <path> | clear | uname [-asnrvmio] | uptime | shutdown [-h|-r] -- halt or reboot the machine"
        , "       lambda -- lambda demo"
        , "       preempt -- preemption demo"
        , "       wastemem <number> -- allocate memory"
        , "       free -- show H.Pages + buddy + ram"
        , "       mem -- show ram/stack/buddy+libc pool/ttbr"
        , "       detect -- show ram/stack/caps"
        , "       vm -- demand pager 100 pages + mmap/mprotect/munmap + isolate + asid+smp shootdown"
        , "       smp -- show SMP cores online | smp up <core> | smp down <core> -- hotplug to ceiling 32, caps mirror online"
        , "       caps -- show capabilities"
        , "       parfib <n> -- parallel fib"
        , "       mvar <n> -- MVar ping-pong test"
        , "       uname [-asnrvmio] [--help] -- print system information (default -s; -a all)"
        , "       ls [path] -- list directory"
        , "       cat <path> -- show file"
        , "       mkdir <path> -- create directory"
        , "       rm <path> -- remove file or empty dir"
        , "       write <path> <text> -- write file (truncate)"
        , "       stat <path> -- show file stat"
        , "       echo <word>... [> /path] -- echo or write via ramfs (volatile 2 MiB pool)"
        , "       ns ls -- list IPC names"
        , "       ns reg <name> -- register name (pl011 launches server)"
        , "       ipc ping <nsName> -- sync call to endpoint"
        , "       ipc grant -- alloc one page and send to pl011"
        , "       ipc el0pp <nsName> -- EL0 ping-pong: server RECV+REPLY + client CALL via the park ring"
        , "       lsdev -- list drivers | dmesg -- kernel log | virtio scan -- probe MMIO slots (0x0a000000+i*0x200)"
        , "       virtio scan|init <slot>|notify <slot>|status|ack <slot>|irqtest <slot>|teardown <slot> -- Virtio-MMIO transport (0x0a000000+i*0x200, split virtqueue, FEATURES_OK VIRTIO_F_VERSION_1|RING_F_EVENT_IDX, dc cvac/dsb, IRQ->Endpoint)"
        , "       blk init <slot>|status <slot>|read <slot> <lba>|write <slot> <lba> <text>|sync [slot]|mount <slot>|teardown <slot> -- Virtio-blk server (Endpoint, Grant, 4K blocks, capacity, queue_notify, IRQ->Endpoint, 64M house.img, Q2=B; ramfs volatile, sync persists HFS1, mount restores)"
        , "       net init <slot>|status <slot>|ifconfig|ping <ip>|udpecho <ip> <port> <text>|arp ls|dhcp|teardown <slot> -- Virtio-net server (Endpoint, Grant, rx0+tx1, 12B hdr, ARP/IPv4/UDP/DHCP, ping, dc ivac/dsb, IRQ->Endpoint, user net 10.0.2.0/24)"
        , "       dns <name> -- A-record lookup via 10.0.2.3 (UDP/53, no TCP; e.g. dns example.com)"
        , "       con init <slot>|status <slot>|write <slot> <text>|read [slot]|teardown <slot>|mirror on|off -- Virtio-console server (ID 3 console / multiport serial port0 + control q2/q3 DEVICE_READY/OPEN, Endpoint, Grant, rx0+tx1, dc ivac/dsb, IRQ->Endpoint; mirror duplicates UART to serial, default off)"
        , "       run </path> [args...] -- load static aarch64 ELF from ramfs 0x01000000 window, argv+env on EL0 stack, svc write/exit/brk/fd/ipc, EL0 eret (TTBR0/ASID/pager)"
        , "       spawn </path> [args...] -- run without waiting (prints pid) | jobs -- list live pids | wait [pid] -- reap (all when bare)"
        , "       fdtest -- per-pid EL1 fd open/write/seek/read/close over ramfs (2 MiB cap; EL0 svc 0x04..0x07+0x0A ride the ring; cross-pid use fails EBADF)"
        , "       forktest -- EL1 forkProc page-map copy + isolation check (no COW/signals; EL0 spawn 0x08 pending ring)"
        ]
    seqFib :: Int -> Int
    seqFib n
      | n <= 1 = n
      | otherwise = seqFib (n - 1) + seqFib (n - 2)
    parFib :: Int -> Int
    parFib n
      | n < 20 = seqFib n
      | otherwise = let a = parFib (n - 1); b = parFib (n - 2) in a `par` b `pseq` a + b
    parFibIO :: Int -> IO Int
    parFibIO n
      | n < 24 = return (parFib n)
      | otherwise = do
          mv <- newEmptyMVar
          -- Bracket the helper thread: an async exception while waiting
          -- must not orphan the forked putter.
          bracket (forkIO $ putMVar mv (parFib (n - 1))) killThread $ \_ -> do
            let b = parFib (n - 2)
            a <- takeMVar mv
            return (a + b)
    mvarTest :: Int -> IO Bool
    mvarTest n = do
      let n' = min n 5000
      r <- timeout (10 * 1000000) $ do
        m <- newEmptyMVar
        forM_ [1 .. n'] $ \_ -> forkIO $ putMVar m (1 :: Int)
        s <- sumMVars n' m 0
        return (s == n')
      return (r == Just True)
      where
        sumMVars 0 _ acc = return acc
        sumMVars k mv acc = do v <- takeMVar mv; sumMVars (k - 1) mv (acc + v)
