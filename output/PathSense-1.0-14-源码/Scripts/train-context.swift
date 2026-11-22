// Run from the repository root: xcrun swift Scripts/train-context.swift
import CreateML
import Foundation
let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let rows = try String(contentsOf: base.appendingPathComponent("Training/sign-layout.csv"), encoding: .utf8).split(whereSeparator: \.isNewline).dropFirst().map { $0.split(separator: ",").map(String.init) }
let data = try MLDataTable(dictionary: ["numbers": rows.map { Int($0[0])! }, "lines": rows.map { Int($0[1])! }, "separators": rows.map { Int($0[2])! }, "directoryWords": rows.map { Int($0[3])! }, "kind": rows.map { $0[4] }])
let parameters = MLLogisticRegressionClassifier.ModelParameters(validation: .none, maxIterations: 80, l1Penalty: 0, l2Penalty: 0.01)
let model = try MLLogisticRegressionClassifier(trainingData: data, targetColumn: "kind", featureColumns: ["numbers", "lines", "separators", "directoryWords"], parameters: parameters)
try model.write(to: base.appendingPathComponent("App/Resources/SignContext.mlmodel"), metadata: MLModelMetadata(author: "PathSense", shortDescription: "Suggests directory layout from anonymous numeric OCR layout features. Can only make a room result more cautious.", version: "1.0"))
