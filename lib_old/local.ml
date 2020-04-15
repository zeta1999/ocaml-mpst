open Base
open Common

module Make
         (EP:S.ENDPOINTS)
         (StaticLin:S.LIN)
         (M:S.MONAD)
         (EV:S.EVENT with type 'a monad = 'a M.t)
       : S.LOCAL
       with type 'a monad = 'a M.t
       with type 't out = 't Out.Make(EP)(M)(EV).out
       with type 't inp = 't Inp.Make(EP)(StaticLin)(M)(EV).inp
       with type close = Close.Make(M).close
       with type 't lin = 't EP.lin
  = struct

  module Inp_ = Inp.Make(EP)(StaticLin)(M)(EV)
  module Out_ = Out.Make(EP)(M)(EV)
  module Close_ = Close.Make(M)

  type 'a monad = 'a M.t
  type 'a lin = 'a EP.lin

  type 't out = 't Out_.out
  type 't inp = 't Inp_.inp
  type close = Close_.close
              
  let receive inp = Inp_.receive (EP.use inp)
  let send = Out_.send
  let sendmany = Out_.sendmany

  let close = Close_.close
end[@@inline]