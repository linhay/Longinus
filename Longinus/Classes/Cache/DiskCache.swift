//
//  DiskCache.swift
//  Longinus
//
//  Created by Qitao Yang on 2020/5/12.
//
//  Copyright (c) 2020 KittenYang <kittenyang@icloud.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
    

import Foundation


public class DiskCache: DiskCacheable {
    
    public typealias Key = String
    public typealias Value = Data
    
    private var storage: KVStorage<Key>?
    private let sizeThreshold: Int32
    private let queue = DispatchQueuePool.default
    private let ioLock: DispatchSemaphore
    
    private(set) var costLimit: Int32
    private(set) var countLimit: Int32
    private(set) var ageLimit: CacheAge
    private(set) var autoTrimInterval: TimeInterval
    
    public var shouldAutoTrim: Bool {
        didSet {
            if oldValue == shouldAutoTrim { return }
            if shouldAutoTrim {
                autoTrim()
            }
        }
    }
    
    public var totalCount: Int32 {
        _ = ioLock.lock()
        let count = storage?.totalItemCount ?? 0
        defer { ioLock.unlock() }
        return count
    }
    
    public var totalCost: Int32 {
        _ = ioLock.lock()
        let count = storage?.totalItemSize ?? 0
        defer { ioLock.unlock() }
        return count
    }

    required public init?(path: String, sizeThreshold threshold: Int32) {
        var type = KVStorageType.automatic
        if threshold == 0 {
            type = .file
        } else if threshold == Int32.max {
            type = .sqlite
        }
        if let currentStorage = KVStorage<Key>(path: path, type: type) {
            storage = currentStorage
        } else {
            return nil
        }
        ioLock = DispatchSemaphore(value: 1)
        sizeThreshold = threshold
        self.countLimit = Int32.max
        self.costLimit = Int32.max
        self.ageLimit = .never
        self.autoTrimInterval = 60
        self.shouldAutoTrim = true
        
        if shouldAutoTrim { autoTrim() }
        
        NotificationCenter.default.addObserver(self, selector: #selector(appWillBeTerminated), name: UIApplication.willTerminateNotification, object: nil)
    }
    
    @objc private func appWillBeTerminated() {
        _ = ioLock.lock()
        storage = nil
        ioLock.unlock()
    }
    
}

// MARK: CacheStandard
extension DiskCache {
    public func containsObject(key: Key) -> Bool {
        _ = ioLock.lock()
        defer { ioLock.unlock() }
        return storage?.containItemforKey(key: key) ?? false
    }
    
    public func query(key: Key) -> Value? {
        _ = ioLock.lock()
        let value = storage?.itemValueForKey(key: key)
        ioLock.unlock()
        return value
    }
    
    public func save(value: Value?, for key: Key) {
        guard let value = value else {
            remove(key: key)
            return
        }
        var filename: String? = nil
        if value.count > sizeThreshold {
            filename = key.lg.md5
        }
        _ = ioLock.lock()
        storage?.save(key: key, value: value, filename: filename)
        ioLock.unlock()
    }
    
    public func save(_ dataWork: @escaping () -> (Value, Int)?, forKey key: Key) {
        if let data = dataWork() {
            self.save(value: data.0, for: key)
        }
    }
    
    public func remove(key: Key) {
        _ = ioLock.lock()
        storage?.remove(forKey: key)
        ioLock.unlock()
    }
    
    /*
     Empties the cache.
     This method may blocks the calling thread until file delete finished.
     */
    public func removeAll() {
        _ = ioLock.lock()
        storage?.remove(allItems: ())
        ioLock.unlock()
    }
}

// MARK: CacheAsyncStandard
extension DiskCache {
    
    public func containsObject(key: Key, _ result: @escaping ((Key, Bool) -> Void)) {
        queue.async { [weak self] in
            guard let self = self else { return }
            result(key, self.containsObject(key: key))
        }
    }
    
    public func query(key: Key, _ result: @escaping ((Key, Value?) -> Void)) {
        queue.async { [weak self] in
            guard let self = self else { return }
            result(key, self.query(key: key))
        }
    }

    public func save(value: Value?, for key: Key, _ result: @escaping (() -> Void)) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.save(value: value, for: key)
            result()
        }
    }
    
    public func save(_ dataWork: @escaping () -> (Value, Int)?, forKey key: Key, result: @escaping (() -> Void)) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.save(dataWork, forKey: key)
            result()
        }
    }
    
    public func remove(key: Key, _ result: @escaping ((Key) -> Void)) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.remove(key: key)
            result(key)
        }
    }
    
    /**
    Empties the cache.
    This method returns immediately and invoke the passed block in background queue
    when the operation finished.
    
    @param result  A block which will be invoked in background queue when finished.
    */
    public func removeAll(_ result: @escaping (() -> Void)) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.removeAll()
            result()
        }
    }
}

extension DiskCache: AutoTrimable {
    
    func trimToAge(_ age: CacheAge) {
        _ = ioLock.lock()
        storage?.remove(earlierThan: age.timeInterval)
        ioLock.unlock()
    }
    
    func trimToCost(_ cost: Int32) {
        _ = ioLock.lock()
        storage?.remove(toFitSize: cost)
        ioLock.unlock()
    }
    
    func trimToCount(_ count: Int32) {
        _ = ioLock.lock()
        storage?.remove(toFitCount: count)
        ioLock.unlock()
    }
    
}
