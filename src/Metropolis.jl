"Types for arbitrary samplers, and a simple Metropolis sampling algorithm."

"""
    AbstractSampler
All samplers should subtype this, and implement the following methods
    `set_temp!(sampler::MySampler, kT::Float64)`
    `sample!(sampler::MySampler)`
"""
abstract type AbstractSampler end


"""
    thermalize!(sampler, num_samples)

`sample!` a sampler a given number of times.
"""
@inline function thermalize!(sampler::S, num_samples::Int) where {S <: AbstractSampler}
    for _ in 1:num_samples
        sample!(sampler)
    end
end


"""
    anneal!(sampler, temp_schedule, step_schedule)

`sample!` a sampler at a series of temperatures, staying at each temperature
  for the number of steps in `step_schedule`.
"""
@inline function anneal!(sampler::S,
                         temp_schedule,
                         step_schedule) where {S <: AbstractSampler}
    for (temp, num_steps) in zip(temp_schedule, step_schedule)
        set_temp!(sampler, temp)
        thermalize!(sampler, num_steps)
    end
end

"""
    anneal!(sampler, temp_function, num_samples)

`sample!` a sampler `num_samples` times, with the sample at timestep `n`
 drawn at a temperature `temp_function(n)`.
"""
@inline function anneal!(sampler::S,
                         temp_function::Function,
                         num_samples::Int) where {S <: AbstractSampler}
    for t in 1:num_steps
        set_temp!(sampler, temp_function(t))
        sample!(sampler) 
    end
end

"""
    MetropolisSampler(sys::SpinSystem, kT::Float64, nsweeps::Int)

A sampler which performs the standard Metropolis Monte Carlo algorithm to
 sample a `SpinSystem` at the requested temperature.

Each single-spin update attempts to move the spin to a random position on
 the unit sphere. One call to `sample!` will attempt to flip each spin
 `nsweeps` times.
"""
mutable struct MetropolisSampler{D, L, Db} <: AbstractSampler
    system     :: SpinSystem{D, L, Db}
    β          :: Float64
    nsweeps    :: Int
    E          :: Float64
    M          :: Vec3
    function MetropolisSampler(sys::SpinSystem{D,L,Db}, kT::Float64, nsweeps::Int) where {D,L,Db}
        @assert kT != 0. "Temperature must be nonzero!"
        new{D, L, Db}(sys, 1.0 / kT, nsweeps, energy(sys), sum(sys))
    end
end

@inline function _random_spin() :: Vec3
    n = randn(Vec3)
    return n / norm(n)
end

"""
    set_temp!(sampler, kT)

Changes the temperature of the sampler to `kT`.
"""
function set_temp!(sampler::MetropolisSampler, kT::Float64)
    sampler.β = 1 / kT
end

"""
    sample!(sampler)

Samples `sampler.system` to a new state, under the Boltzmann distribution
 as defined by `sampler.system.hamiltonian`.
"""
function sample!(sampler::MetropolisSampler)
    for _ in 1:sampler.nsweeps
        for idx in CartesianIndices(sampler.system)
            # Try to rotate this spin to somewhere randomly on the unit sphere
            new_spin = _random_spin()
            ΔE = local_energy_change(sampler.system, idx, new_spin)

            if rand() < exp(-sampler.β * ΔE)
                sampler.E += ΔE
                sampler.M += (new_spin - sampler.system[idx])
                sampler.system[idx] = new_spin
            end
        end
    end
end

@inline running_energy(sampler::MetropolisSampler) = sampler.E
@inline running_mag(sampler::MetropolisSampler) = sampler.M


"""
    local_energy_change(sys, idx, newspin)

Computes the change in energy if we replace the spin at `sys[idx]`
  with `newspin`.
"""
function local_energy_change(sys::SpinSystem{D}, idx, newspin::Vec3) where {D}
    ℋ = sys.hamiltonian
    ΔE = 0.0
    oldspin = sys[idx]
    spindiff = newspin - oldspin
    (i, cell) = splitidx(idx)

    if !isnothing(ℋ.ext_field)
        ΔE -= ℋ.ext_field.B ⋅ spindiff
    end
    for heisen in ℋ.heisenbergs
        J = heisen.J
        for bond in heisen.bonds[i]
            Sⱼ = sys[bond.j, offset(cell, bond.n, sys.lattice.size)]
            ΔE += heisen.J * (spindiff ⋅ Sⱼ)
        end
    end
    if !isnothing(ℋ.on_sites)
        J = ℋ.on_sites.Js[i]
        ΔE += newspin ⋅ (J .* newspin) - oldspin ⋅ (J .* oldspin)
    end
    for diag_coup in ℋ.diag_coups
        for (J, bond) in zip(diag_coup.Js[i], diag_coup.bonds[i])
            Sⱼ = sys[bond.j, offset(cell, bond.n, sys.lattice.size)]
            ΔE += (J .* spindiff) ⋅ Sⱼ
        end
    end
    for gen_coup in ℋ.gen_coups
        for (J, bond) in zip(gen_coup.Js[i], gen_coup.bonds[i])
            Sⱼ = sys[bond.j, offset(cell, bond.n, sys.lattice.size)]
            ΔE += dot(spindiff, J, Sⱼ)
        end
    end
    if !isnothing(ℋ.dipole_int)
        throw("Local energy changes not implemented yet for dipole interactions")
    end
    return ΔE
end
