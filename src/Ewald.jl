""" Implements Ewald summation rules for monopoles and dipoles on lattices
"""

import Base.Cartesian.@ntuple
using SpecialFunctions
using Parameters

@doc raw"""
    ewald_sum_monopole(sys::ChargeSystem; η=1.0, extent=10)

Performs ewald summation to calculate the potential energy of a 
system of monopoles with PBC.

Specifically, computes:
```math
    U = \frac{1}{2} \sum_{i,j} q_i q_j \left\{
        \sum_{\boldsymbol{n}}^{'} \frac{\mathrm{erfc}(η|\boldsymbol{r}_{ij}
            + \boldsymbol{n}|)}{|\boldsymbol{r}_{ij} + \boldsymbol{n}|}
      + \frac{4π}{V} \sum_{\boldsymbol{k} \ne 0} \frac{e^{-k^2/4η^2}}{k^2}
            e^{i\boldsymbol{k}\cdot\boldsymbol{r}_{ij}} \right\}
      - \frac{π}{2Vη^2}Q^2 - \frac{η}{\sqrt{π}} \sum_{i} q_i^2
```
"""
function ewald_sum_monopole(sys::ChargeSystem{D, L, Db}; η=1.0, extent=5) :: Float64 where {D, L, Db}
    extent_idxs = CartesianIndices(ntuple(_->-extent:extent, Val(D)))

    @unpack sites, lattice = sys

    recip = gen_reciprocal(lattice)
    vol = volume(lattice)
    # Vectors spanning the axes of the entire system
    superlat_vecs = lattice.size' .* lattice.lat_vecs

    tot_charge_term = -π / (2 * vol * η^2) * sum(sys.sites)^2
    charge_square_term = -η / √π * (sys.sites |> x->x.^2 |> sum)

    real_space_sum, recip_space_sum = 0.0, 0.0
    real_site_sum, recip_site_sum = 0.0, 0.0

    n = @MVector zeros(D)
    k = @MVector zeros(D)

    for idx1 in eachindex(lattice)
        rᵢ = lattice[idx1]
        qᵢ = sys.sites[idx1]
        for idx2 in eachindex(lattice)
            rⱼ = lattice[idx2]
            qⱼ = sys.sites[idx2]
            rᵢⱼ = rⱼ - rᵢ

            # TODO: Either merge into one sum, or separately control extents
            # Real-space sum over unit cells
            real_site_sum = 0.0
            for cell_idx in extent_idxs
                cell_idx = convert(SVector, cell_idx)
                mul!(n, superlat_vecs, cell_idx)

                if all(rᵢⱼ .== 0) && all(n .== 0)
                    continue
                end

                dist = norm(rᵢⱼ + n)
                real_site_sum += erfc(η * dist) / dist
            end
            real_space_sum += qᵢ * qⱼ * real_site_sum

            # Reciprocal-space sum
            recip_site_sum = 0.0
            for cell_idx in extent_idxs
                cell_idx = convert(SVector, cell_idx)
                mul!(k, recip.lat_vecs, cell_idx)

                k2 = norm(k) ^ 2
                if k2 ≈ 0
                    continue
                end
                recip_site_sum += exp(-k2 / 4η^2) * exp(im * (k ⋅ rᵢⱼ)) / k2
            end
            recip_space_sum += qᵢ * qⱼ * recip_site_sum
        end
    end

    return 0.5 * real_space_sum + 2π / vol * real(recip_space_sum) + tot_charge_term + charge_square_term
end

function direct_sum_monopole(sys::ChargeSystem{D}; s=0.0, extent=5) :: Float64 where {D}
    extent_idxs = CartesianIndices(ntuple(_->-extent:extent, Val(D)))

    @unpack sites, lattice = sys
    dim = length(lattice.size)

    # Vectors spanning the axes of the entire system
    superlat_vecs = lattice.size' .* lattice.lat_vecs

    brav_sites = view(sites, fill(:, D)..., 1)

    real_space_sum = 0.0
    real_site_sum = 0.0

    n = @MVector zeros(D)

    for idx1 in eachindex(lattice)
        rᵢ = lattice[idx1]
        qᵢ = sys.sites[idx1]
        for idx2 in eachindex(lattice)
            rⱼ = lattice[idx2]
            qⱼ = sys.sites[idx2]
            rᵢⱼ = rⱼ - rᵢ

            # Real-space sum over unit cells
            real_site_sum = 0.0
            for cell_idx in extent_idxs
                cell_idx = convert(SVector, cell_idx)
                mul!(n, superlat_vecs, cell_idx)

                if all(rᵢⱼ .== 0) && all(n .== 0) || norm(n) > extent
                    continue
                end

                # prefactor = all(n .== 0) ? 0.5 : 1.0
                prefactor = 0.5

                dist = norm(rᵢⱼ + n)
                real_site_sum += prefactor / dist * exp(-s * norm(n)^2)
            end
            real_space_sum += qᵢ * qⱼ * real_site_sum
        end
    end

    return real_space_sum
end

@doc raw"""
    ewald_sum_dipole(sys::SpinSystem; η=1.0, extent=10)

Performs ewald summation to calculate the potential energy of a 
system of dipoles with PBC.
"""
function ewald_sum_dipole(sys::SpinSystem{D, L, Db}; extent=2, η=1.0) :: Float64 where {D, L, Db}
    extent_idxs = CartesianIndices(ntuple(_->-extent:extent, Val(D)))

    @unpack sites, lattice = sys

    recip = gen_reciprocal(lattice)
    vol = volume(lattice)
    # Vectors spanning the axes of the entire system
    superlat_vecs = lattice.size' .* lattice.lat_vecs

    dip_square_term = -2η^3 / (3 * √π) * sum(norm.(sys.sites).^2)

    real_space_sum, recip_space_sum = 0.0, 0.0
    real_site_sum = 0.0

    n = @MVector zeros(D)
    k = @MVector zeros(D)

    for idx1 in eachindex(lattice)
        @inbounds rᵢ = lattice[idx1]
        @inbounds pᵢ = sys.sites[idx1]

        for idx2 in eachindex(lattice)
            @inbounds rⱼ = lattice[idx2]
            @inbounds pⱼ = sys.sites[idx2]
            pᵢ_dot_pⱼ = pᵢ ⋅ pⱼ

            rᵢⱼ = rⱼ - rᵢ

            # TODO: Either merge into one sum, or separately control extents
            # Real-space sum over unit cells
            real_site_sum = 0.0
            for cell_idx in extent_idxs
                cell_idx = convert(SVector, cell_idx)
                mul!(n, superlat_vecs, cell_idx)

                rᵢⱼ_n = rᵢⱼ + n

                if all(rᵢⱼ_n .== 0)
                    continue
                end

                dist = norm(rᵢⱼ_n)
                exp_term = 2η / √π * dist * exp(-η^2 * dist^2)
                erfc_term = erfc(η * dist)

                # Terms from Eq. 79 of Beck
                real_site_sum += (exp_term + erfc_term) / dist^3
                
                # Calculating terms from Eq. 80 + 81 of Beck
                prefactor = -3 * (pᵢ ⋅ rᵢⱼ_n) * (pⱼ ⋅ rᵢⱼ_n) / dist^5
                real_space_sum += prefactor * ((2η^2 * dist^2 / 3 + 1) * exp_term + erfc_term)
            end
            real_space_sum += (pᵢ ⋅ pⱼ) * real_site_sum

            # Reciprocal-space sum
            for cell_idx in extent_idxs
                cell_idx = convert(SVector, cell_idx)
                mul!(k, recip.lat_vecs, cell_idx)

                k2 = norm(k)^2
                if k2 == 0
                    continue
                end
                recip_space_sum += exp(-k2 / 4η^2) * cos(k ⋅ rᵢⱼ) * (pᵢ ⋅ k) * (pⱼ ⋅ k) / k2
            end

        end
    end

    return 0.5 * real_space_sum + 2π / vol * real(recip_space_sum) + dip_square_term
end

function precompute_monopole_ewald(lattice::Lattice{D}; extent=10, η=1.0) :: Array{Float64} where {D}
    A = zeros(size(lattice)..., size(lattice)...)
    N = prod(size(lattice))
    extent_idxs = CartesianIndices(ntuple(_->-extent:extent, Val(D)))

    dim = length(lattice.size)

    recip = gen_reciprocal(lattice)
    vol = volume(lattice)
    # Vectors spanning the axes of the entire system
    superlat_vecs = lattice.size' .* lattice.lat_vecs

     # Indexing into this reshape avoids a ton of allocations from CartesianIndex nonsense
    A_N = reshape(A, N, N)
    # Put the charge-squared term on the diagonal
    for i in 1:N
        @inbounds A_N[i, i] += -η / √π
        for j in 1:N
            @inbounds A_N[i, j] += -π / (2 * vol * η^2)
        end
    end

    real_space_sum, recip_space_sum = 0.0, 0.0
    real_site_sum, recip_site_sum = 0.0, 0.0

    n = @MVector zeros(D)
    k = @MVector zeros(D)

    lin_inds = LinearIndices(lattice)

    for idx1 in eachindex(lattice)
        @inbounds rᵢ = lattice[idx1]
        @inbounds i = lin_inds[idx1]
        for idx2 in eachindex(lattice)
            @inbounds rⱼ = lattice[idx2]
            @inbounds j = lin_inds[idx2]
            rᵢⱼ = rⱼ - rᵢ

            # TODO: Either merge into one sum, or separately control extents
            # Real-space sum over unit cells
            real_site_sum = 0.0
            for cell_idx in extent_idxs
                cell_idx = convert(SVector, cell_idx)
                mul!(n, superlat_vecs, cell_idx)

                if all(rᵢⱼ .== 0) && all(n .== 0)
                    continue
                end

                dist = norm(rᵢⱼ + n)
                real_site_sum += erfc(η * dist) / dist
            end
            @inbounds A_N[i, j] += 0.5 * real_site_sum

            # Reciprocal-space sum
            recip_site_sum = 0.0
            for cell_idx in extent_idxs
                cell_idx = convert(SVector, cell_idx)
                mul!(k, recip.lat_vecs, cell_idx)

                k2 = norm(k) ^ 2
                if k2 ≈ 0
                    continue
                end
                recip_site_sum += exp(-k2 / 4η^2) * cos(k ⋅ rᵢⱼ) / k2
            end
            @inbounds A_N[i, j] += 2π / vol * recip_site_sum
        end
    end

    return A
end

function precompute_monopole_ewald_compressed(lattice::Lattice{D}; extent=10, η=1.0) :: OffsetArray{Float64} where {D}
    nb = length(lattice.basis_vecs)
    A = zeros(Float64, nb, nb, map(n->2*(n-1)+1, lattice.size)...)
    A = OffsetArray(A, 1:nb, 1:nb, map(n->-(n-1):n-1, lattice.size)...)

    extent_idxs = CartesianIndices(ntuple(_->-extent:extent, Val(D)))
    delta_idxs = CartesianIndices(ntuple(n->-(lattice.size[n]-1):(lattice.size[n]-1), Val(D)))

    recip = gen_reciprocal(lattice)
    vol = volume(lattice)
    # Vectors spanning the axes of the entire system
    superlat_vecs = lattice.size' .* lattice.lat_vecs

    # Put the dipole-squared term on the diagonal
    # for i in 1:N
    #     @inbounds A_N[i, i, 1, 1] += -η / √π
    #     for j in 1:N
    #         @inbounds A_N[i, j, 1, 1] += -π / (2 * vol * η^2)
    #     end
    # end

    # Handle charge-squared and total charge terms
    A .+= -π / (2 * vol * η^2)
    for i in 1:nb
        @inbounds A[i, i, zero(CartesianIndex{D})] += -η / √π
    end

    real_space_sum, recip_space_sum = 0.0, 0.0
    real_site_sum, recip_site_sum = 0.0, 0.0

    n = @MVector zeros(D)
    k = @MVector zeros(D)

    for idx in delta_idxs
        for b1 in 1:nb
            @inbounds rᵢ = lattice.basis_vecs[b1]
            for b2 in 1:nb
                @inbounds rⱼ = lattice[b2, idx]
                rᵢⱼ = rⱼ - rᵢ

                # TODO: Either merge into one sum, or separately control extents
                # Real-space sum over unit cells
                real_site_sum = 0.0
                for cell_idx in extent_idxs
                    cell_idx = convert(SVector, cell_idx)
                    mul!(n, superlat_vecs, cell_idx)

                    if all(rᵢⱼ .== 0) && all(n .== 0)
                        continue
                    end

                    dist = norm(rᵢⱼ + n)
                    real_site_sum += erfc(η * dist) / dist
                end
                # @inbounds A_N[i, j, 1, 1] += 0.5 * real_site_sum
                @inbounds A[b2, b1, idx] += 0.5 * real_site_sum

                # Reciprocal-space sum
                recip_site_sum = 0.0
                for cell_idx in extent_idxs
                    cell_idx = convert(SVector, cell_idx)
                    mul!(k, recip.lat_vecs, cell_idx)

                    k2 = norm(k) ^ 2
                    if k2 ≈ 0
                        continue
                    end
                    recip_site_sum += exp(-k2 / 4η^2) * cos(k ⋅ rᵢⱼ) / k2
                end
                # @inbounds A_N[i, j, 1, 1] += 2π / vol * recip_site_sum
                @inbounds A[b2, b1, idx] += 2π / vol * recip_site_sum
            end
        end
    end

    return A
end

function contract_monopole(sys::ChargeSystem, A::Array{Float64}) :: Float64
    # Check A has the right shape
    @assert size(A) == (size(sys)..., size(sys)...)

    U = 0.0
    for i in eachindex(sys)
        @inbounds qᵢ = sys[i]
        for j in eachindex(sys)
            @inbounds qⱼ = sys[j]
            @inbounds U += qᵢ * A[i, j] * qⱼ
        end
    end
    return U
end

function contract_monopole_compressed(sys::ChargeSystem, A::OffsetArray{Float64}) :: Float64
    nb = length(sys.lattice.basis_vecs)
    U = 0.0
    for i in bravindexes(sys.lattice)
        for ib in 1:nb
            @inbounds qᵢ = sys[ib, i]
            for j in bravindexes(sys.lattice)
                for jb in 1:nb
                    @inbounds qⱼ = sys[jb, j]
                    @inbounds U += qᵢ * A[ib, jb, i - j] * qⱼ
                end
            end
        end
    end
    return U
end

"Precompute the dipole interaction matrix"
function precompute_dipole_ewald(lattice::Lattice{D, L, Db}; extent=10, η=1.0) :: Array{SMatrix{3, 3, Float64, 9}} where {D, L, Db}
    A = zeros(SMatrix{3, 3, Float64, 9}, size(lattice)..., size(lattice)...)
    N = prod(size(lattice))
    extent_idxs = CartesianIndices(ntuple(_->-extent:extent, Val(D)))

    recip = gen_reciprocal(lattice)
    vol = volume(lattice)
    # Vectors spanning the axes of the entire system
    superlat_vecs = lattice.size' .* lattice.lat_vecs

    iden = SMatrix{3, 3, Float64, 9}(diagm(ones(3)))

    # Indexing into this reshape avoids a ton of allocations from CartesianIndex nonsense
    A_N = reshape(A, N, N)
    # Put the dipole-squared term on the diagonal
    for i in 1:N
        @inbounds A_N[i, i] = A_N[i, i] .+ -2η^2 / (3 * √π) * iden
    end

    real_space_sum, recip_space_sum = 0.0, 0.0
    real_site_sum = 0.0

    n = @MVector zeros(D)
    k = @MVector zeros(D)
    real_tensor = @MMatrix zeros(3, 3)
    recip_tensor = @MMatrix zeros(3, 3)

    lin_inds = LinearIndices(lattice)

    for idx1 in eachindex(lattice)
        @inbounds rᵢ = lattice[idx1]
        @inbounds i = lin_inds[idx1] 
        for idx2 in eachindex(lattice)
            @inbounds rⱼ = lattice[idx2]
            @inbounds j = lin_inds[idx2]

            rᵢⱼ = rⱼ - rᵢ

            # TODO: Either merge into one sum, or separately control extents
            # Real-space sum over unit cells
            real_site_sum = 0.0
            fill!(real_tensor, 0.0)
            for cell_idx in extent_idxs
                cell_idx = convert(SVector, cell_idx)
                mul!(n, superlat_vecs, cell_idx)

                rᵢⱼ_n = rᵢⱼ + n

                if all(rᵢⱼ_n .== 0)
                    continue
                end

                dist = norm(rᵢⱼ_n)
                exp_term = 2η / √π * dist * exp(-η^2 * dist^2)
                erfc_term = erfc(η * dist)

                # Terms from Eq. 79 of Beck
                real_site_sum += (exp_term + erfc_term) / dist^3
                
                # Calculating terms from Eq. 80 + 81 of Beck
                prefactor = -3 * ((2η^2 * dist^2 / 3 + 1) * exp_term + erfc_term) / dist^5
                @. real_tensor += prefactor * (rᵢⱼ_n * rᵢⱼ_n')
            end
            @inbounds real_tensor .+= real_site_sum * iden
            @inbounds A_N[i, j] = A_N[i, j] .+ 0.5 * real_tensor


            # Reciprocal-space sum
            fill!(recip_tensor, 0.0)
            for cell_idx in extent_idxs
                cell_idx = convert(SVector, cell_idx)
                mul!(k, recip.lat_vecs, cell_idx)

                k2 = norm(k)^2
                if k2 == 0
                    continue
                end

                prefactor = exp(-k2 / 4η^4) * cos(k ⋅ rᵢⱼ) / k2
                @. recip_tensor += prefactor * (k * k')
            end
            @inbounds A_N[i, j] = A_N[i, j] .+ 2π / vol * recip_tensor
        end
    end

    return A
end

"Precompute the dipole interaction matrix, in compressed form with a single spatial index of the difference between sites."
function precompute_dipole_ewald_compressed(lattice::Lattice{D, L, Db}; extent=10, η=1.0) :: OffsetArray{SMatrix{3, 3, Float64, 9}} where {D, L, Db}
    nb = length(lattice.basis_vecs)
    A = zeros(SMatrix{3, 3, Float64, 9}, nb, nb, map(n->2*(n-1)+1, lattice.size)...)
    A = OffsetArray(A, 1:nb, 1:nb, map(n->-(n-1):n-1, lattice.size)...)

    extent_idxs = CartesianIndices(ntuple(_->-extent:extent, Val(D)))
    delta_idxs = CartesianIndices(ntuple(n->-(lattice.size[n]-1):(lattice.size[n]-1), Val(D)))

    recip = gen_reciprocal(lattice)
    vol = volume(lattice)
    # Vectors spanning the axes of the entire system
    superlat_vecs = lattice.size' .* lattice.lat_vecs

    iden = SMatrix{3, 3, Float64, 9}(diagm(ones(3)))

    # Put the dipole-squared term on the zero-difference matrix
    for i in 1:nb
        A[i, i, 0, 0, 0] = A[i, i, 0, 0, 0] .+ -2η^2 / (3 * √π) * iden
    end

    real_space_sum, recip_space_sum = 0.0, 0.0
    real_site_sum = 0.0

    n = @MVector zeros(D)
    k = @MVector zeros(D)
    real_tensor = @MMatrix zeros(3, 3)
    recip_tensor = @MMatrix zeros(3, 3)

    for idx in delta_idxs
        for b1 in 1:nb
            @inbounds rᵢ = lattice.basis_vecs[b1]
            for b2 in 1:nb
                @inbounds rⱼ = lattice[b2, idx]
                rᵢⱼ = rⱼ - rᵢ

                # TODO: Either merge into one sum, or separately control extents
                # Real-space sum over unit cells
                real_site_sum = 0.0
                fill!(real_tensor, 0.0)
                for cell_idx in extent_idxs
                    cell_idx = convert(SVector, cell_idx)
                    mul!(n, superlat_vecs, cell_idx)

                    rᵢⱼ_n = rᵢⱼ + n

                    if all(rᵢⱼ_n .== 0)
                        continue
                    end

                    dist = norm(rᵢⱼ_n)
                    exp_term = 2η / √π * dist * exp(-η^2 * dist^2)
                    erfc_term = erfc(η * dist)

                    # Terms from Eq. 79 of Beck
                    real_site_sum += (exp_term + erfc_term) / dist^3
                    
                    # Calculating terms from Eq. 80 + 81 of Beck
                    prefactor = -3 * ((2η^2 * dist^2 / 3 + 1) * exp_term + erfc_term) / dist^5
                    @. real_tensor += prefactor * (rᵢⱼ_n * rᵢⱼ_n')
                end
                @inbounds real_tensor .+= real_site_sum * iden
                @inbounds A[b2, b1, idx] = A[b2, b1, idx] .+ 0.5 * real_tensor

                # Reciprocal-space sum
                fill!(recip_tensor, 0.0)
                for cell_idx in extent_idxs
                    cell_idx = convert(SVector, cell_idx)
                    mul!(k, recip.lat_vecs, cell_idx)

                    k2 = norm(k)^2
                    if k2 == 0
                        continue
                    end

                    prefactor = exp(-k2 / 4η^4) * cos(k ⋅ rᵢⱼ) / k2
                    @. recip_tensor += prefactor * (k * k')
                end
                @inbounds A[b2, b1, idx] = A[b2, b1, idx] .+ 2π / vol * recip_tensor
            end
        end
    end

    return A
end

function contract_dipole(sys::SpinSystem, A::Array{SMatrix{3, 3, Float64, 9}}) :: Float64
    # Check A has the right shape
    @assert size(A) == (size(sys)..., size(sys)...)
    N = prod(size(sys))
    A_N = reshape(A, N, N)

    U = 0.0
    # For some mysterious reason, using eachindex(sys) causes a ton of allocations
    #  but not in the compressed version or in contract_monopole...
    for i in 1:N
        @inbounds pᵢ = sys[i]
        for j in 1:N
            @inbounds pⱼ = sys[j]
            @inbounds U += pᵢ' * A_N[j, i] * pⱼ
        end
    end

    return U
end

function contract_dipole_compressed(sys::SpinSystem, A::OffsetArray{SMatrix{3, 3, Float64, 9}}) :: Float64
    nb = length(sys.lattice.basis_vecs)
    U = 0.0
    for i in bravindexes(sys.lattice)
        for ib in 1:nb
            @inbounds pᵢ = sys[ib, i]
            for j in bravindexes(sys.lattice)
                for jb in 1:nb
                    @inbounds pⱼ = sys[jb, j]
                    @inbounds U += pᵢ' * A[ib, jb, i - j] * pⱼ
                end
            end
        end
    end
    return U
end

"""Approximates a dipolar `SpinSystem` by generating a monopolar `ChargeSystem` consisting of
    opposite charges Q = ±1/(2ϵ) separated by displacements d = 2ϵp centered on the original
    lattice sites.
"""
function _approx_dip_as_mono(sys::SpinSystem{D, L, Db}; ϵ::Float64=0.1) :: ChargeSystem{D, L, Db} where {D, L, Db}
    @unpack sites, lattice = sys

    # Need to expand the underlying unit cell to the entire system size
    new_lat_vecs = lattice.size' .* lattice.lat_vecs
    new_latsize = @SVector ones(Int, D)

    new_nbasis = 2 * prod(size(sites))
    new_sites = zeros(new_nbasis, 1, 1, 1)
    new_basis = Vector{SVector{D, Float64}}()
    sizehint!(new_basis, new_nbasis)

    ib = 1
    for idx in eachindex(lattice)
        @inbounds r = lattice[idx]
        @inbounds p = sites[idx]

        # Add new charges as additional basis vectors
        push!(new_basis, SVector{3}(r .+ ϵ * p))
        push!(new_basis, SVector{3}(r .- ϵ * p))

        # Set these charges to ±1/2ϵ
        new_sites[1, 1, 1, ib]   =  1 / 2ϵ
        new_sites[1, 1, 1, ib+1] = -1 / 2ϵ

        ib += 2
    end

    new_lattice = Lattice(new_lat_vecs, new_basis, new_latsize)

    return ChargeSystem{D, L, Db}(new_lattice, new_sites)
end

"Self-energy of a physical dipole with moment p, and displacement d=2ϵ"
function _dipole_self_energy(; p::Float64=1.0, ϵ::Float64=0.1)
    d, q = 2ϵ, p/2ϵ
    return -q^2 / d
end

function test_compression(A, Acomp)
    ndim = div(ndims(A), 2) - 1
    nb = size(A, 1)
    latsize = size(A)[2:1+ndim]
    for i in CartesianIndices(latsize)
        for j in CartesianIndices(latsize)
            for ib in 1:nb
                for jb in 1:nb
                    @assert A[ib, i, jb, j] ≈ Acomp[ib, jb, i - j]
                end
            end
        end
    end
end