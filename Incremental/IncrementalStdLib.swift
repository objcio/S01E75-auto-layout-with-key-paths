//
//  IncrementalStdLib.swift
//  Incremental
//
//  Created by Chris Eidhof on 19.09.17.
//  Copyright © 2017 objc.io. All rights reserved.
//

import Foundation

// idea make certain properties configurable from "the outside". We could make an "ExternalConfig" struct which reads from JSON (and is settable by the server).

public func if_<A: Equatable>(_ condition: I<Bool>, then l: I<A>, else r: I<A>) -> I<A> {
    return condition.flatMap { $0 ? l : r }
}

public func if_<A: Equatable>(_ condition: I<Bool>, then l: A, else r: A) -> I<A> {
    return condition.map { $0 ? l : r }
}

public func &&(l: I<Bool>, r: I<Bool>) -> I<Bool> {
    return l.zip2(r, { $0 && $1 })
}

public func ||(l: I<Bool>, r: I<Bool>) -> I<Bool> {
    return l.zip2(r, { $0 || $1 })
}

public func ??<A: Equatable>(l: I<A?>, r: A) -> I<A> {
    return l.map { $0 ?? r }
}

public prefix func !(l: I<Bool>) -> I<Bool> {
    return l.map { !$0 }
}

public func ==<A>(l: I<A>, r: I<A>) -> I<Bool> where A: Equatable {
    return l.zip2(r, ==)
}

public func ==<A>(l: I<A>, r: A) -> I<Bool> where A: Equatable {
    return l.map { $0 == r }
}

public func ==<A>(l: I<A?>, r: A?) -> I<Bool> where A: Equatable {
    return l.map { $0 == r }
}
