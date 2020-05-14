//
//  LonginusManager.swift
//  Longinus
//
//  Created by Qitao Yang on 2020/5/13.
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

public class LonginusManager {
    
    public static let shared: LonginusManager = { () -> LonginusManager in
        let path = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first! + "/\(LonginusPrefixID)"
        return LonginusManager(cachePath: path, sizeThreshold: 20 * 1024)
    }()
    
    public private(set) var imageCache: ImageCache
    public private(set) var imageDownloader: ImageDownloadable
    public private(set) var imageCoder: ImageCodeable
    private let coderQueue: DispatchQueuePool
    private var tasks: Set<ImageLoadTask>
    private var preloadTasks: Set<ImageLoadTask>
    private var taskLock: Mutex
    private var urlBlacklistLock: Mutex
    private var taskSentinel: Int32
    private var urlBlacklist: Set<URL>
    
    public var currentTaskCount: Int {
        taskLock.locked { [weak self] () -> (Int) in
            return self?.tasks.count ?? 0
        }
    }
    
    public var currentPreloadTaskCount: Int {
        taskLock.locked { [weak self] () -> (Int) in
            return self?.preloadTasks.count ?? 0
        }
    }
    
    public convenience init(cachePath: String, sizeThreshold: Int) {
        let cache = ImageCache(path: cachePath, sizeThreshold: sizeThreshold)
        let downloader = MergeTaskImageDownloader(sessionConfiguration: URLSessionConfiguration.default)
        let coder = ImageCoderManager()
        cache.imageCoder = coder
        downloader.imageCoder = coder

        self.init(cache: cache, downloader: downloader, coder: coder)
    }
    
    public init(cache: ImageCache, downloader: ImageDownloadable, coder: ImageCodeable) {
        imageCache = cache
        imageDownloader = downloader
        imageCoder = coder
        coderQueue = DispatchQueuePool.userInitiated
        tasks = Set()
        preloadTasks = Set()
        taskSentinel = 0
        taskLock = Mutex()
        urlBlacklistLock = Mutex()
        urlBlacklist = Set()
    }
    
    @discardableResult
    public func loadImage(with resource: ImageWebCacheResourceable,
                          options: ImageOptions = .none,
                          transformer: ImageTransformer? = nil,
                          progress: ImageDownloaderProgressBlock? = nil,
                          completion: @escaping ImageManagerCompletionBlock) -> ImageLoadTask {
        let task = newLoadTask()
        taskLock.locked { [weak self] in
            self?.tasks.insert(task)
            if options.contains(.preload) { self?.preloadTasks.insert(task) }
        }
        
        if !options.contains(.retryFailedUrl) {
            var inBlacklist: Bool = false
            urlBlacklistLock.locked { [weak self] in
                inBlacklist = self?.urlBlacklist.contains(resource.downloadUrl) ?? false
            }

            if inBlacklist {
                complete(with: task, completion: completion, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist, userInfo: [NSLocalizedDescriptionKey : "URL is blacklisted"]))
                remove(loadTask: task)
                return task
            }
        }
        
        if options.contains(.refreshCache) {
            downloadImage(with: resource,
                          options: options,
                          task: task,
                          transformer: transformer,
                          progress: progress,
                          completion: completion)
            return task
        }
        
        // Get memory image
        var memoryImage: UIImage?
        imageCache.image(forKey: resource.cacheKey, cacheType: .memory) { (result: ImageCacheQueryCompletionResult) in
            switch result {
            case let .memory(image: image):
                memoryImage = image
            default:
                break
            }
        }
        var finished = false
        if let currentImage = memoryImage {
            if options.contains(.preload) {
                complete(with: task,
                         completion: completion,
                         image: currentImage,
                         data: nil,
                         cacheType: .memory)
                remove(loadTask: task)
                finished = true
            } else if !options.contains(.queryDataWhenInMemory) {
                if var animatedImage = currentImage as? AnimatedImage {
                    animatedImage.lg.transformer = transformer
                    complete(with: task,
                             completion: completion,
                             image: animatedImage,
                             data: nil,
                             cacheType: .memory)
                    remove(loadTask: task)
                    finished = true
                } else if let currentEditor = transformer {
                    if currentEditor.key == currentImage.lg.lgImageEditKey {
                        complete(with: task,
                                 completion: completion,
                                 image: currentImage,
                                 data: nil,
                                 cacheType: .memory)
                        remove(loadTask: task)
                        finished = true
                    } else if currentImage.lg.lgImageEditKey == nil {
                        coderQueue.async { [weak self, weak task] in
                            guard let self = self, let task = task, !task.isCancelled else { return }
                            if var image = currentEditor.edit(currentImage) {
                                guard !task.isCancelled else { return }
                                image.lg.lgImageEditKey = currentEditor.key
                                image.lg.imageFormat = currentImage.lg.imageFormat
                                self.complete(with: task,
                                              completion: completion,
                                              image: image,
                                              data: nil,
                                              cacheType: .memory)
                                self.imageCache.store(image,
                                                      data: nil,
                                                      forKey: resource.cacheKey,
                                                      cacheType: .memory,
                                                      completion: {})
                            } else {
                                self.complete(with: task, completion: completion, error: NSError(domain: LonginusImageErrorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey : "No edited image"]))
                            }
                            self.remove(loadTask: task)
                        }
                        finished = true
                    }
                } else if currentImage.lg.lgImageEditKey == nil {
                    complete(with: task,
                             completion: completion,
                             image: currentImage,
                             data: nil,
                             cacheType: .memory)
                    remove(loadTask: task)
                    finished = true
                }
            }
        }
        if finished { return task }
        
        if options.contains(.ignoreDiskCache) || resource.downloadUrl.isFileURL {
            downloadImage(with: resource,
                          options: options.union(.ignoreDiskCache),
                          task: task,
                          transformer: transformer,
                          progress: progress,
                          completion: completion)
        } else if options.contains(.preload) {
            // Check whether disk data exists
            imageCache.diskDataExists(forKey: resource.cacheKey) { (exists) in
                if exists {
                    self.complete(with: task,
                                  completion: completion,
                                  image: nil,
                                  data: nil,
                                  cacheType: .disk)
                    self.remove(loadTask: task)
                } else {
                    self.downloadImage(with: resource,
                                       options: options,
                                       task: task,
                                       transformer: transformer,
                                       progress: progress,
                                       completion: completion)
                }
            }
        } else {
            // Get disk data
            imageCache.image(forKey: resource.cacheKey, cacheType: .disk) { [weak self, weak task] (result: ImageCacheQueryCompletionResult) in
                guard let self = self, let task = task, !task.isCancelled else { return }
                switch result {
                case let .disk(data: data):
                    self.handle(imageData: data,
                                options: options,
                                cacheType: (memoryImage != nil ? .all : .disk),
                                forTask: task,
                                resource: resource,
                                transform: transformer,
                                completion: completion)
                case .none:
                    // Download
                    self.downloadImage(with: resource,
                                       options: options,
                                       task: task,
                                       transformer: transformer,
                                       progress: progress,
                                       completion: completion)
                default:
                    print("Error: illegal query disk data result")
                    break
                }
            }
        }
        return task
    }
    
    @discardableResult
    public func preload(_ resources: [ImageWebCacheResourceable],
                        options: ImageOptions = .none,
                        progress: ImagePreloadProgress? = nil,
                        completion: ImagePreloadCompletion? = nil) -> [ImageLoadTask] {
        cancelPreloading()
        let total = resources.count
        if total <= 0 { return [] }
        var finishCount = 0
        var successCount = 0
        var tasks: [ImageLoadTask] = []
        for resource in resources {
            var currentOptions: ImageOptions = .preload
            if options.contains(.useURLCache) { currentOptions.insert(.useURLCache) }
            if options.contains(.handleCookies) { currentOptions.insert(.handleCookies) }
            let task = loadImage(with: resource, options: currentOptions) { (_, _, error, _) in
                finishCount += 1
                if error == nil { successCount += 1 }
                progress?(successCount, finishCount, total)
                if finishCount >= total {
                    completion?(successCount, total)
                }
            }
            tasks.append(task)
        }
        return tasks
    }
    
    func remove(loadTask: ImageLoadTask) {
        taskLock.locked { [weak self] in
            self?.tasks.remove(loadTask)
            self?.preloadTasks.remove(loadTask)
        }
    }
    
    /// Cancels image preloading tasks
    public func cancelPreloading() {
        var currentTasks = Set<ImageLoadTask>()
        taskLock.locked {
            currentTasks = preloadTasks
        }
        for task in currentTasks {
            task.cancel()
        }
    }
    
    /// Cancels all image loading tasks
    public func cancelAll() {
        var currentTasks = Set<ImageLoadTask>()
        taskLock.locked {
            currentTasks = tasks
        }
        for task in currentTasks {
            task.cancel()
        }
    }

}

extension LonginusManager {
    private func newLoadTask() -> ImageLoadTask {
        let task = ImageLoadTask(sentinel: OSAtomicIncrement32(&taskSentinel))
        task.imageManager = self
        return task
    }
    
    private func handle(imageData data: Data,
                        options: ImageOptions,
                        cacheType: ImageCacheType,
                        forTask task: ImageLoadTask,
                        resource: ImageWebCacheResourceable,
                        transform: ImageTransformer?,
                        completion: @escaping ImageManagerCompletionBlock) {
        if options.contains(.preload) {
            complete(with: task,
                     completion: completion,
                     image: nil,
                     data: data,
                     cacheType: cacheType)
            if cacheType == .none {
                imageCache.store(nil, data: data, forKey: resource.cacheKey, cacheType: .disk) {
                }
            }
            remove(loadTask: task)
            return
        }
        self.coderQueue.async { [weak self, weak task] in
            guard let self = self, let task = task, !task.isCancelled else { return }
            let decodedImage = self.imageCoder.decodedImage(with: data)
            if let currentEditor = transform {
                if var animatedImage = decodedImage as? AnimatedImage {
                    animatedImage.lg.transformer = currentEditor
                    self.complete(with: task,
                                  completion: completion,
                                  image: animatedImage,
                                  data: data,
                                  cacheType: cacheType)
                    let storeCacheType: ImageCacheType = (cacheType == .disk || options.contains(.ignoreDiskCache) ? .memory : .all)
                    self.imageCache.store(animatedImage,
                                          data: data,
                                          forKey: resource.cacheKey,
                                          cacheType: storeCacheType,
                                          completion:{
                    })
                } else if let inputImage = decodedImage {
                    if var image = currentEditor.edit(inputImage) {
                        guard !task.isCancelled else { return }
                        image.lg.lgImageEditKey = currentEditor.key
                        image.lg.imageFormat = data.lg.imageFormat
                        self.complete(with: task,
                                      completion: completion,
                                      image: image,
                                      data: data,
                                      cacheType: cacheType)
                        let storeCacheType: ImageCacheType = (cacheType == .disk || options.contains(.ignoreDiskCache) ? .memory : .all)
                        self.imageCache.store(image,
                                              data: data,
                                              forKey: resource.cacheKey,
                                              cacheType: storeCacheType,
                                              completion:{})
                    } else {
                        self.complete(with: task, completion: completion, error: NSError(domain: LonginusImageErrorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey : "No edited image"]))
                    }
                } else {
                    if cacheType == .none {
                        self.urlBlacklistLock.locked { [weak self] in
                            self?.urlBlacklist.insert(resource.downloadUrl)
                        }
                    }
                    self.complete(with: task, completion: completion, error: NSError(domain: LonginusImageErrorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey : "Invalid image data"]))
                }
            } else if var image = decodedImage {
                if !options.contains(.ignoreImageDecoding),
                    let decompressedImage = self.imageCoder.decompressedImage(with: image, data: data) {
                    image = decompressedImage
                }
                self.complete(with: task,
                              completion: completion,
                              image: image,
                              data: data,
                              cacheType: cacheType)
                let storeCacheType: ImageCacheType = (cacheType == .disk || options.contains(.ignoreDiskCache) ? .memory : .all)
                self.imageCache.store(image,
                                      data: data,
                                      forKey: resource.cacheKey,
                                      cacheType: storeCacheType,
                                      completion: {})
            } else {
                if cacheType == .none {
                    self.urlBlacklistLock.locked { [weak self] in
                        self?.urlBlacklist.insert(resource.downloadUrl)
                    }
                }
                self.complete(with: task, completion: completion, error: NSError(domain: LonginusImageErrorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey : "Invalid image data"]))
            }
            self.remove(loadTask: task)
        }
    }
    
    private func downloadImage(with resource: ImageWebCacheResourceable,
                               options: ImageOptions,
                               task: ImageLoadTask,
                               transformer: ImageTransformer?,
                               progress: ImageDownloaderProgressBlock?,
                               completion: @escaping ImageManagerCompletionBlock) {
        task.downloadTask = self.imageDownloader.downloadImage(with: resource.downloadUrl, options: options, progress: progress) { [weak self, weak task] (data: Data?, error: Error?) in
            guard let self = self, let task = task, !task.isCancelled else { return }
            if let currentData = data {
                if options.contains(.retryFailedUrl) {
                    self.urlBlacklistLock.locked { [weak self] in
                        self?.urlBlacklist.remove(resource.downloadUrl)
                    }
                }
                self.handle(imageData: currentData,
                            options: options,
                            cacheType: .none,
                            forTask: task,
                            resource: resource,
                            transform: transformer,
                            completion: completion)
            } else if let currentError = error {
                let code = (currentError as NSError).code
                if  code != NSURLErrorNotConnectedToInternet &&
                    code != NSURLErrorCancelled &&
                    code != NSURLErrorTimedOut &&
                    code != NSURLErrorInternationalRoamingOff &&
                    code != NSURLErrorDataNotAllowed &&
                    code != NSURLErrorCannotFindHost &&
                    code != NSURLErrorCannotConnectToHost &&
                    code != NSURLErrorNetworkConnectionLost {
                    self.urlBlacklistLock.locked { [weak self] in
                        self?.urlBlacklist.insert(resource.downloadUrl)
                    }
                }
                
                self.complete(with: task, completion: completion, error: currentError)
                self.remove(loadTask: task)
            } else {
                print("Error: illegal result of download")
            }
        }
    }
    
    private func complete(with task: ImageLoadTask,
                          completion: @escaping ImageManagerCompletionBlock,
                          image: UIImage?,
                          data: Data?,
                          cacheType: ImageCacheType) {
        complete(with: task,
                 completion: completion,
                 image: image,
                 data: data,
                 error: nil,
                 cacheType: cacheType)
    }
    
    private func complete(with task: ImageLoadTask, completion: @escaping ImageManagerCompletionBlock, error: Error) {
        complete(with: task,
                 completion: completion,
                 image: nil,
                 data: nil,
                 error: error,
                 cacheType: .none)
    }
    
    private func complete(with task: ImageLoadTask,
                          completion: @escaping ImageManagerCompletionBlock,
                          image: UIImage?,
                          data: Data?,
                          error: Error?,
                          cacheType: ImageCacheType) {
        DispatchQueue.main.lg.safeAsync { [weak self] in
            guard self != nil, !task.isCancelled else { return }
            completion(image, data, error, cacheType)
        }
    }
}