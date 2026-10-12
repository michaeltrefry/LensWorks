import Foundation
import Darwin
import Testing
@testable import Compositor

@MainActor
struct FloatScratchWriterOwnershipTests {
    private enum Failure: Error { case injected }
    private func cleanup(_ directory: URL) { try? FileManager.default.removeItem(at: directory) }
    @Test func registeredF64ReaderRetainsItsWorkspaceUntilLastFieldRelease() throws {
        var workspace: LWFloatWorkspace? = try LWFloatWorkspace(workingSet: LWFloatWorkingSet(limit: 4*1024*1024))
        let root = workspace!.directory, child = try workspace!.makeScratchDirectory()
        defer { cleanup(root) }
        var field: LWFloatDoubleRows? = try LWFloatDoubleRows.create(width: 3, height: 2,
            workingSet: workspace!.workingSet, directory: child, fileOwner: workspace) { y in
            [Double(y), Double(bitPattern: 0x3ff0000000000001), -0.0]
        }
        workspace = nil
        #expect(FileManager.default.fileExists(atPath: root.path))
        let row = try field!.read(1)
        #expect(row.values.map(\.bitPattern) == [Double(1).bitPattern, 0x3ff0000000000001, (-0.0 as Double).bitPattern])
        field = nil
        #expect(!FileManager.default.fileExists(atPath: root.path))
        withExtendedLifetime(row) {}
    }
    @Test func failedLaterRowLeavesOnlyRegisteredEarlierRowForRetirement() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet(limit: 4*1024*1024))
        let root = workspace.directory, child = try workspace.makeScratchDirectory()
        defer { cleanup(root) }
        do {
            _ = try LWFloatDoubleRows.create(width: 2, height: 2, workingSet: workspace.workingSet,
                directory: child, fileOwner: workspace) { y in
                if y == 1 { throw Failure.injected }; return [1.0, -2.0]
            }
            Issue.record("Injected row failure was swallowed")
        } catch Failure.injected {} // Require the actual injected branch, not an unrelated refusal.
        #expect(try FileManager.default.contentsOfDirectory(atPath: child.path) == ["00000000.f64"])
        try workspace.retireOwnedChildren()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func unexpectedF64SiblingIsPreservedBeforeAnyRegisteredMemberDeletion() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet(limit: 4*1024*1024))
        let root = workspace.directory, child = try workspace.makeScratchDirectory()
        defer { cleanup(root) }
        var field: LWFloatDoubleRows? = try LWFloatDoubleRows.create(width: 2, height: 1, workingSet: workspace.workingSet,
            directory: child, fileOwner: workspace) { _ in [3.0, 5.0] }
        let sentinel = child.appendingPathComponent("unexpected.txt")
        try Data([0x75]).write(to: sentinel, options: .withoutOverwriting)
        guard chmod(sentinel.path, 0o600) == 0 else { throw ProjectError.invalid }
        do { try workspace.retireOwnedChildren(); Issue.record("Unexpected member was adopted") }
        catch { #expect(error is ProjectError) }
        #expect(try Data(contentsOf: sentinel) == Data([0x75]))
        #expect(try field!.read(0).values == [3.0, 5.0])
        field = nil
        // With the real reader released, the remaining refusal is the unexpected
        // named member, not an unrelated active-token gate.
        do { try workspace.retireOwnedChildren(); Issue.record("Unexpected member was adopted after reader release") }
        catch { #expect(error is ProjectError) }
        #expect(try Data(contentsOf: sentinel) == Data([0x75]))
        try FileManager.default.removeItem(at: sentinel)
        try workspace.retireOwnedChildren()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func sameF64BytesAtReplacementInodeAreNotAdopted() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet(limit: 4*1024*1024))
        let root = workspace.directory, child = try workspace.makeScratchDirectory()
        defer { cleanup(root) }
        var field: LWFloatDoubleRows? = try LWFloatDoubleRows.create(width: 2, height: 1, workingSet: workspace.workingSet,
            directory: child, fileOwner: workspace) { _ in [7.0, 11.0] }
        let original = child.appendingPathComponent("00000000.f64"), displaced = child.appendingPathComponent("displaced.f64")
        let bytes = try Data(contentsOf: original)
        try FileManager.default.moveItem(at: original, to: displaced)
        try bytes.write(to: original, options: .withoutOverwriting)
        guard chmod(original.path, 0o444) == 0 else { throw ProjectError.invalid }
        // Remove the displaced original only within this private test's cleanup authority;
        // its name is not a registered replacement adopted by the workspace.
        try FileManager.default.removeItem(at: displaced)
        do { try field!.read(0); Issue.record("Reader adopted replacement inode") }
        catch { #expect(error is ProjectError) }
        field = nil // Release the token; exact replacement custody remains invalid.
        do { try workspace.retireOwnedChildren(); Issue.record("Retirement adopted replacement inode") }
        catch { #expect(error is ProjectError) }
        #expect(try Data(contentsOf: original) == bytes)
    }

    @Test func activeF64ReaderRefusesRetirementAndCapturedCancellationStopsCachedRead() throws {
        let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet(limit:4*1024*1024))
        let root=workspace.directory,child=try workspace.makeScratchDirectory();defer{cleanup(root)}
        var field:LWFloatDoubleRows?=try LWFloatDoubleRows.create(width:2,height:1,workingSet:workspace.workingSet,
            directory:child,fileOwner:workspace){_ in [Double.pi,-0.0]}
        var reader:LWFloatDoubleRows.Reader?=LWFloatDoubleRows.Reader(field!)
        let expected=try Data(contentsOf:child.appendingPathComponent("00000000.f64"))
        #expect(try reader!.row(0).values.map(\.bitPattern)==[Double.pi.bitPattern,(-0.0 as Double).bitPattern])
        field=nil
        do{try workspace.retireOwnedChildren();Issue.record("Active f64 reader lost its registered lifetime")}
        catch{#expect(error is ProjectError)}
        #expect(try Data(contentsOf:child.appendingPathComponent("00000000.f64"))==expected)
        workspace.cancellation.cancel()
        #expect(throws:CancellationError.self){_ = try reader!.row(0)}
        reader=nil
        try workspace.retireOwnedChildren();#expect(!FileManager.default.fileExists(atPath:root.path))
    }
}


extension FloatScratchWriterOwnershipTests {
    @Test(arguments:[false,true])
    func escapedF64ValuesAndSlicesRetainTheirChargeAfterFieldRetirement(sliceOnly:Bool) throws {
        let working=try LWFloatWorkingSet(limit:4*1024*1024)
        var workspace:LWFloatWorkspace?=try LWFloatWorkspace(workingSet:working)
        var field:LWFloatDoubleRows?=try LWFloatDoubleRows.create(width:3,height:1,workingSet:working,
            directory:try workspace!.makeScratchDirectory(),fileOwner:workspace) { _ in [Double.pi,-0.0,7] }
        var values:LWFloatDoubleRows.Row.Values?=try field!.read(0).values
        var slice:LWFloatDoubleRows.Row.Values.SubSequence?
        if sliceOnly { slice=values![1..<3];values=nil }
        field=nil
        try workspace!.retireOwnedChildren();workspace=nil
        #expect(working.retainedBytes>0)
        #expect(throws:ProjectError.self) { _=try working.reserve(working.limit) }
        if sliceOnly { #expect(slice?.first?.bitPattern==(-0.0 as Double).bitPattern && slice?.last==7) }
        else { #expect(values?.first?.bitPattern==Double.pi.bitPattern && values?.last==7) }
        values=nil;slice=nil
        let full=try working.reserve(working.limit);withExtendedLifetime(full) {}
    }
    @Test func explicitAdmittedF64CopyMutationConservesItsImmutableInput() throws {
        let working=try LWFloatWorkingSet(limit:4*1024*1024)
        let workspace=try LWFloatWorkspace(workingSet:working)
        var field:LWFloatDoubleRows?=try LWFloatDoubleRows.create(width:3,height:1,workingSet:working,
            directory:workspace.makeScratchDirectory(),fileOwner:workspace) { _ in [Double.pi,-0.0,7] }
        do {
            let values=try field!.read(0).values
            let copyCharge=try working.reserve(LWFloatDoubleRows.rowBytes(3))
            var output=Array(values);output[0]=11;output[1]=3
            #expect(values.map(\.bitPattern)==[Double.pi.bitPattern,(-0.0 as Double).bitPattern,Double(7).bitPattern])
            #expect(output==[11,3,7])
            withExtendedLifetime(copyCharge) {}
        }
        field=nil;try workspace.retireOwnedChildren()
    }
}
