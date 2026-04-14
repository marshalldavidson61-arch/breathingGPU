using Test
using GrugBreathMap

@testset "GrugBreathMap Tests" begin
    
    @testset "Error Types" begin
        @test WrongHoleError("test") isa GrugLoudScreamError
        @test GpuCousinDeadError("test") isa GrugLoudScreamError
        @test MachineDeadError("test") isa GrugLoudScreamError
        @test MissingOperationError("test") isa GrugLoudScreamError
        @test GhostWorkerDiedError("test", Exception("oops")) isa GrugLoudScreamError
        @test GpuFallbackRequiredError("test", GpuCousinDeadError("dead")) isa GrugLoudScreamError
        
        # Grug errors are LOUD
        err = WrongHoleError("bad hole")
        @test occursin("WRONG HOLE", sprint(showerror, err))
        
        err = GhostWorkerDiedError("rotate", Exception("test error"))
        @test occursin("GHOST WORKER DIED", sprint(showerror, err))
    end
    
    @testset "GrugHole Construction" begin
        hole = GrugHole("test_hole")
        @test hole.name == "test_hole"
        @test hole.state == PLACEHOLDER_STATE
        @test hole.current_juice == hole.baseline_juice
        @test hole.active_ghosts == 0
        @test hole.streak == 0
        @test hole.ghost_graveyard == 0  # No dead ghosts yet
    end
    
    @testset "BreathMap Construction" begin
        map = BreathMap()
        @test map.breathe_flag[] == true
        @test length(map.holes) == 8
        @test haskey(map.holes, "rotate")
        @test haskey(map.holes, "translate")
        @test haskey(map.holes, "scale")
        @test haskey(map.holes, "project")
        @test haskey(map.holes, "reflect")
        @test haskey(map.holes, "intersect")
        @test haskey(map.holes, "extrude")
        @test haskey(map.holes, "boolean")
        @test isempty(map.dead_ghosts_report)  # No dead ghosts yet
    end
    
    @testset "WrongHoleError" begin
        map = BreathMap()
        @test_throws WrongHoleError do_geometry!(map, "nonexistent_hole", 1, 2, 3)
    end
    
    @testset "MachineDeadError" begin
        map = BreathMap()
        kill_map!(map)
        @test map.breathe_flag[] == false
        @test_throws MachineDeadError do_geometry!(map, "rotate", 1, 2, 3)
    end
    
    @testset "Status Functions" begin
        map = BreathMapWithTricks()
        status = map_status(map)
        @test status["breathing"] == true
        @test status["num_holes"] == 8
        @test haskey(status, "holes")
        @test haskey(status, "total_dead_ghosts")
        @test haskey(status, "dead_ghosts_report")
        
        hole_stat = hole_status(map.holes["rotate"])
        @test hole_stat["name"] == "rotate"
        @test hole_stat["state"] == "PLACEHOLDER_STATE"
        @test haskey(hole_stat, "dead_ghosts")
    end
    
    @testset "CPU Operations" begin
        map = BreathMapWithTricks()
        
        # Test rotation
        point = [1.0, 0.0, 0.0]
        rotated = do_geometry!(map, "rotate", point, π/2, [0.0, 0.0, 1.0])
        @test isapprox(rotated[1], 0.0, atol=1e-10)
        @test isapprox(rotated[2], 1.0, atol=1e-10)
        
        # Test translation
        translated = do_geometry!(map, "translate", point, [1.0, 2.0, 3.0])
        @test translated == [2.0, 2.0, 3.0]
        
        # Test scaling
        scaled = do_geometry!(map, "scale", point, 2.0)
        @test scaled == [2.0, 0.0, 0.0]
    end
    
    @testset "Metabolic Activation" begin
        map = BreathMapWithTricks()
        hole = map.holes["rotate"]
        
        # Initial state
        initial_juice = hole.current_juice
        
        # Do some work
        for i in 1:5
            do_geometry!(map, "rotate", [1.0, 0.0, 0.0], 0.1, [0.0, 0.0, 1.0])
        end
        
        # Juice should have increased
        @test hole.current_juice > initial_juice
        @test hole.streak >= 5
    end
    
    @testset "Kill and Cleanup" begin
        map = BreathMapWithTricks()
        @test map.breathe_flag[] == true
        
        kill_map!(map)
        
        @test map.breathe_flag[] == false
        @test all(h.active_ghosts == 0 for h in values(map.holes))
    end
    
    @testset "Dead Ghost Reporting" begin
        map = BreathMapWithTricks()
        
        # Get dead ghosts report (should be empty initially)
        report = get_dead_ghosts_report(map)
        @test isempty(report)
        
        # Check status includes dead ghost tracking
        status = map_status(map)
        @test haskey(status, "total_dead_ghosts")
        @test status["total_dead_ghosts"] == 0
    end
    
    @testset "Explicit Fallback Function" begin
        map = BreathMapWithTricks()
        
        # do_geometry_with_fallback! should work for CPU operations
        point = [1.0, 0.0, 0.0]
        rotated = do_geometry_with_fallback!(map, "rotate", point, π/2, [0.0, 0.0, 1.0])
        @test isapprox(rotated[1], 0.0, atol=1e-10)
        @test isapprox(rotated[2], 1.0, atol=1e-10)
    end
    
    @testset "No Silent GPU Fallback" begin
        map = BreathMapWithTricks()
        
        # Force a hole into GPU state by pumping juice
        hole = map.holes["rotate"]
        hole.current_juice = 0.9  # Above GPU threshold
        
        # Since has_gpu() returns false, GPU operation should SCREAM
        # (No silent fallback in do_geometry!)
        @test_throws GpuCousinDeadError do_geometry!(map, "rotate", [1.0, 0.0, 0.0], 0.1, [0.0, 0.0, 1.0])
    end
end