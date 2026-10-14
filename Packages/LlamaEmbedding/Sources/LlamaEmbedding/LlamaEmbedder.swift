// Adapted from DigUp (https://github.com/ARahim3/DigUp), Copyright (c) 2026 Abdur Rahim, MIT License.

import CLlama
import Foundation

public struct EmbeddingError: Error, CustomStringConvertible {
  public let description: String
  init(_ description: String) { self.description = description }
}

/// EmbeddingGemma 2 on llama.cpp with Metal. The image encoder (mtmd) feeds the text model. The vector is the text
/// model's mean-pooled, L2-normalized output. Use one thread at a time.
public final class LlamaEmbedder {
  public static let dimension = 768
  /// Changes only when the produced vectors change: the model files, llama.cpp, image sizing, or prompts.
  public static let vectorVersion = 1
  public static let imageBudget = 280

  public let supportsImages: Bool
  private var model: OpaquePointer?
  private var context: OpaquePointer?
  private var media: OpaquePointer?
  private var batch: OpaquePointer?
  private let vocab: OpaquePointer?
  private let embeddingSize: Int
  private let rowSize: Int
  private let maxTokens = 1024
  private static let maxSequences = 16
  private var sequences: Int32 = 0
  private var tokens = 0
  private var position: llama_pos = 0

  /// `media` is nil for a text-only embedder.
  public init(text: URL, media mediaFile: URL?) throws {
    _ = Self.backend
    var modelParams = llama_model_default_params()
    modelParams.n_gpu_layers = 999
    guard let model = llama_model_load_from_file(text.path, modelParams) else {
      throw EmbeddingError("The text model could not be loaded.")
    }
    var params = llama_context_default_params()
    params.n_ctx = UInt32(maxTokens)
    params.n_batch = UInt32(maxTokens)
    params.n_ubatch = UInt32(maxTokens)
    params.n_seq_max = UInt32(Self.maxSequences)
    params.kv_unified = true
    params.embeddings = true
    params.pooling_type = LLAMA_POOLING_TYPE_MEAN
    guard let context = llama_init_from_model(model, params) else {
      llama_model_free(model)
      throw EmbeddingError("The model context could not be created.")
    }
    var media: OpaquePointer?
    if let mediaFile {
      var mediaParams = mtmd_context_params_default()
      mediaParams.use_gpu = true
      mediaParams.print_timings = false
      mediaParams.warmup = true
      mediaParams.image_min_tokens = 1   // Images arrive at their final size.
      mediaParams.image_max_tokens = Int32(Self.imageBudget)
      media = mtmd_init_from_file(mediaFile.path, model, mediaParams)
      if media == nil {
        llama_free(context)
        llama_model_free(model)
        throw EmbeddingError("The image model could not be loaded.")
      }
    }
    self.model = model
    self.context = context
    self.media = media
    supportsImages = media != nil
    batch = llama_batch_ext_init(context)
    vocab = llama_model_get_vocab(model)
    embeddingSize = Int(llama_model_n_embd_out(model))
    rowSize = Int(llama_model_n_embd_inp(model))
    // The first calls build the Metal pipelines.
    do {
      for _ in 0..<2 { _ = try embed(texts: [EmbeddingPrompts.query("warm up")]) }
    } catch {
      close()
      throw error
    }
  }

  deinit { close() }

  public func close() {
    if let batch { llama_batch_ext_free(batch) }
    if let media { mtmd_free(media) }
    if let context { llama_free(context) }
    if let model { llama_model_free(model) }
    (batch, media, context, model) = (nil, nil, nil, nil)
  }

  /// One normalized vector per text, in order. Texts longer than the context are cut.
  public func embed(texts: [String]) throws -> [[Float]] {
    reset()
    var vectors: [[Float]] = []
    for text in texts {
      let tokens = tokenize(text)
      if sequences == Self.maxSequences || self.tokens + tokens.count > maxTokens { vectors += try run() }
      begin()
      for token in tokens { try add(token: token) }
    }
    if sequences > 0 { vectors += try run() }
    return vectors
  }

  /// Packed RGB pixels at the size `ImageSizing.targetSize` returns for `imageBudget`.
  public func embed(rgb pixels: [UInt8], width: Int, height: Int) throws -> [Float] {
    guard media != nil else { throw EmbeddingError("This embedder was started without the image model.") }
    guard pixels.count == width * height * 3,
          let bitmap = pixels.withUnsafeBufferPointer({ mtmd_bitmap_init(UInt32(width), UInt32(height), $0.baseAddress) })
    else { throw EmbeddingError("The image could not be prepared.") }
    defer { mtmd_bitmap_free(bitmap) }
    let chunks = mtmd_input_chunks_init()
    defer { mtmd_input_chunks_free(chunks) }
    var bitmaps: [OpaquePointer?] = [bitmap]
    let status = String(cString: mtmd_default_marker()).withCString { marker in
      var text = mtmd_input_text(text: marker, text_len: strlen(marker), add_special: true, parse_special: true)
      return mtmd_tokenize(media, chunks, &text, &bitmaps, 1)
    }
    guard status == 0 else { throw EmbeddingError("The image could not be tokenized (\(status)).") }
    reset()
    begin()
    for index in 0..<mtmd_input_chunks_size(chunks) {
      let chunk = mtmd_input_chunks_get(chunks, index)
      if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
        var count = 0
        guard let tokens = mtmd_input_chunk_get_tokens_text(chunk, &count) else { continue }
        for i in 0..<count { try add(token: tokens[i]) }
      } else {
        guard mtmd_encode_chunk(media, chunk) == 0, let rows = mtmd_get_output_embd(media) else {
          throw EmbeddingError("The image encoder failed.")
        }
        try add(rows: rows, count: mtmd_input_chunk_get_n_tokens(chunk))
      }
    }
    return try run()[0]
  }

  /// `<bos> text <eos>`, cut to `maxTokens` with both special tokens kept.
  private func tokenize(_ text: String) -> [llama_token] {
    let utf8 = Array(text.utf8CString)
    var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
    var count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
    if count < 0 {
      tokens = [llama_token](repeating: 0, count: Int(-count))
      count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
    }
    tokens.removeLast(tokens.count - Int(max(count, 0)))
    if tokens.count > maxTokens {
      tokens = Array(tokens[0..<(maxTokens - 1)]) + [llama_vocab_eos(vocab)]
    }
    return tokens
  }

  private func begin() {
    sequences += 1
    position = 0
  }

  private func reset() {
    llama_batch_ext_clear(batch)
    sequences = 0
    tokens = 0
  }

  private func add(token: llama_token) throws {
    try place(llama_batch_ext_add_token(batch, sequences - 1, token))
  }

  private func add(rows: UnsafeMutablePointer<Float>, count: Int) throws {
    for row in 0..<count {
      let embd = llama_embd(data: rows + row * rowSize, n_rows: 1, n_embd: rowSize)
      try place(llama_batch_ext_add_embd(batch, sequences - 1, embd))
    }
  }

  private func place(_ index: Int32) throws {
    guard index >= 0 else { throw EmbeddingError("The batch is full (\(index)).") }
    var pos: [llama_pos] = [position, 0, 0, 0]
    guard llama_batch_ext_set_pos(batch, index, &pos), llama_batch_ext_set_output_embd(batch, index, true) else {
      throw EmbeddingError("Token \(index) could not be placed.")
    }
    position += 1
    tokens += 1
  }

  private func run() throws -> [[Float]] {
    defer { reset() }
    let status = llama_process(context, LLAMA_PROCESS_TYPE_ENCODE, batch)
    guard status == 0 else { throw EmbeddingError("llama_process failed (\(status)).") }
    return try (0..<sequences).map { sequence in
      guard let pooled = llama_get_embeddings_seq(context, sequence) else {
        throw EmbeddingError("No pooled embedding for input \(sequence).")
      }
      var sum = 0.0
      for i in 0..<embeddingSize { sum += Double(pooled[i]) * Double(pooled[i]) }
      let scale = sum > 0 ? Float(1 / sum.squareRoot()) : 0
      return (0..<embeddingSize).map { pooled[$0] * scale }
    }
  }

  /// llama.cpp's process-wide setup. Only warnings and errors are logged.
  private static let backend: Void = {
    llama_log_set({ level, text, _ in
      guard let text, level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR else { return }
      FileHandle.standardError.write(Data(String(cString: text).utf8))
    }, nil)
    mtmd_helper_log_set({ level, text, _ in
      guard let text, level == GGML_LOG_LEVEL_ERROR else { return }
      FileHandle.standardError.write(Data(String(cString: text).utf8))
    }, nil)
    llama_backend_init()
  }()
}
