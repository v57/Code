import Foundation

/// Types are read from their tokens when someone asks, then kept. `unknown` absorbs: nothing on it is answered or reported.
package indirect enum Ty: Hashable {
  case unknown
  case module(Name)
  case nominal(DeclRef, [Ty])
  case meta(Ty)
  case tuple([Ty], [Name])
  case function([Ty], Ty)
  case optional(Ty)
  case param(Name, DeclRef?)
  case selfType
  case existential([Ty])
  /// `S.Element`, of a parameter that isn't known yet: not the receiver's `Element`.
  case dependent(Ty, Name)
}
